Write-Output "Title: Runbook_CheckSpecificMG_tag_all_resources_and_move_subscriptions_to_correct_MG.ps1`nDate: YYYY-MM-DD`nDescription: Used to tag all subscriptions and resources in '<staging MG>' with RBAC owner (primary-owner-email), created date (resource-build-date), Environment (environment) and Primary work group (primary-group), then move subscription to correct Management Group based on active state.`n"

Try {
    # 1. Ensure the module is imported in the session
    Write-Output "Importing Az.Accounts"
    Import-Module -Name Az.Accounts -ErrorAction Stop
    Write-Output "Importing Az.ResourceGraph"
    Import-Module -Name Az.ResourceGraph -ErrorAction Stop

    # 2. Authenticate using the Runbook's Managed Identity
    Disable-AzContextAutosave -Scope Process | Out-Null
    # It is often used with -Scope Process (e.g., Disable-AzContextAutosave -Scope Process) inside Azure Automation runbooks, 
    # scripts, or CI/CD pipelines to prevent a script from accidentally leaking or carrying over credentials into subsequent processes
    Connect-AzAccount -Identity -Environment AzureCloud -ErrorAction Stop | Out-Null
}
Catch { 
    Write-Error "WARNING - Unable to import required modules because $_"
    Exit
}

$env:SuppressAzurePowerShellBreakingChangeWarnings = "true" # Suppress warning messages
$subscriptions = ""
$uniqueGroupSubscription = ""
$uniqueSubscriptionIndex = 1
$timestamp = get-date -format yyyyMMdd:hh_mm_ssz

###################################################################################################
# SET THE NAMES OF THE TAGS AND THE MANAGEMENT GROUPS TO USE, ALSO THE ENTRA ADMINS TO IGNORE
###################################################################################################

$tagNamePrimaryOwnerEmail = "primary-owner-email"
$tagNameResourceBuildDate = "resource-build-date"

$tagNamePrimaryGroup = "primary-group"
$tagValuePrimaryGroup = "<enter default tag value i.e HelpDesk>"
$tagNameEnvironment = "environment"
$tagValueEnvironment = "<enter default tag value i.e. Production>"

$adminDomainEmailToIgnoreRBAC = "@<yourtenant>.onmicrosoft.com"
$RBACAdminEmail = "helpdesk@<yourtenant>" # This is used incase ONLY entra admins exist as the owner, so removing them would leave the field empty. This adds a default placeholder

# FOR STAGING (temp/holding) MG of Subscriptions. Will move to either DISABLED or ENABLED MG depending on state
$managementGroupToSearch = "<insert name of MG used to house the staging subscriptions>"
$disabledManagementGroupName = "<insert name of MG used to house the disabled state subscriptions>"
$enabledManagementGroupName = "<insert name of MG used to house the enabled state subscriptions>"

###################################################################################################
# SET THE NAMES OF THE TAGS AND THE MANAGEMENT GROUPS TO USE, ALSO THE ENTRA ADMINS TO IGNORE
###################################################################################################

Try { # This gets the ID's of every subscription found in the 'staging' MG you set above
$subscriptions = Get-AzManagementGroupSubscription -GroupID $managementGroupToSearch | Select-object -ExpandProperty Id | ForEach-Object { $_ -replace '.*/', '' } 
}
Catch {
    Write-Error "WARNING - Unable to get list of subscriptions because $_"
    Exit
}

If(!$subscriptions -or ($subscriptions -eq "")){
	Write-Output "No subscriptions found in '$managementGroupToSearch'... exiting"
	Exit
} Else {
	Write-Output "[$timeStamp] Starting scan of $($subscriptions.Count) subscriptions in '$managementGroupToSearch'..."
}

# For each subscription found, check the state (if disabled move to the disabled MG and move onto the next as you can't tag anything that is disabled)
# If enabled, then retrieve and stamp build dates and RBAC owner, along with standard baseline tags. Then move to enabled MG

ForEach ($uniqueGroupSubscription in $subscriptions) {
    
    $uniqueSubscription = ""
    $azGraphManagementGroupQuery = ""
    $subscriptionManagementGroup = ""
    $rbacOwners = ""
	$rbacUniqueOwners = ""
	$primaryOwnerEmail = ""
	$currentTagDefinitions = ""
	$currentTags = ""

    $insertNewTagPrimaryOwnerEmail = ""
    $insertNewTagResourceBuildDate = ""
    $insertNewTagPrimaryGroup = ""
    $insertNewTagEnvironment = ""

    $subscriptionInitialBuildFormattedDate = ""
    $subscriptionInitialBuildAZLog = ""
    $subscriptionInitialBuildAZLogFormattedDate = ""

    $resourceGroupReturnedJSON = ""
    $resourceGroupEarliestCreationTimestamp = ""
    $resourceGroupEarliestCreationTimestampFormattedDate = ""

    $apiCheckForResourceGroupCreatedTime = ""
    $apiCheckForResourceGroupCreatedTimeResponse = ""

    #Set the context to the current subscription
	Try {
    	$uniqueSubscription = Get-AzSubscription -subscriptionID $uniqueGroupSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 
    	$null = Set-AzContext -SubscriptionId $($uniqueSubscription.Id) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null 
	} Catch {
		Write-Output "Not able to find subscription called $uniqueGroupSubscription..."
		Continue
	}

    If($uniqueSubscription) { # Only checks on a valid, found subscription

        ##############################################################################
        ####### RETRIEVE THE MANAGEMENT GROUP LEVEL THE SUBSCRIPTION IS LOCATED ######
        $azGraphManagementGroupQuery = "resourcecontainers | where type == 'microsoft.resources/subscriptions' and subscriptionId == '$($uniqueSubscription.Id)' | project properties.managementGroupAncestorsChain"
        $subscriptionManagementGroup = (Search-AzGraph -Query $azGraphManagementGroupQuery).properties_managementGroupAncestorsChain[0] 
	
        ###################################################################
        ###################################################################
        # If the state of the Subscription is Active, move to Enabled Management Group
        # If the state of the Subscription is Disabled/Warned, move to the Disabled Management Group

        If ($($uniqueSubscription.State) -eq "Disabled" -or $($uniqueSubscription.State) -eq "Warned") { 

            Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)'... verifying"
            # If the state is disabled (or Warned) BUT the subscription is already in the DISABLED MG, then just leave alone...
            If($($subscriptionManagementGroup.Name) -eq $disabledManagementGroupName){
                # Do nothing - the disabled subscription is already in the disabled MG
                Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)'... Skipping"
            }
            Else { # This means the subscription is DISABLED and needs to be moved to the disabled MG
                Write-Output "Migration Status: $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)'... moving to '$disabledManagementGroupName'"
                Try {
                    New-AzManagementGroupSubscription -GroupID $disabledManagementGroupName -SubscriptionId $($uniqueSubscription.Id) -ErrorAction Stop | Out-Null
                    Write-Output "Successfully moved $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' from '$($subscriptionManagementGroup.Name)' to '$disabledManagementGroupName'"
                }
                Catch {
                    Write-Error "WARNING - Failed to move $($uniqueSubscription.Id) ($($uniqueSubscription.Name)) because: $_"
                }
            }
        }
        ElseIf ($($uniqueSubscription.State) -eq "Enabled") { #This means that that Subscription is Active/Enabled so we continue to check and stamp tags / move etc...

            Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)'... verifying"
        
            ###################################################################
            ###### RETRIEVE THE CURRENT LIST OF TAGS ON THE SUBSCRIPTION ######
	        # Get the current list of tags on the subscription
	        $currentTagDefinitions = Get-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -ErrorAction SilentlyContinue
            $currentTags = if ($currentTagDefinitions) { $currentTagDefinitions.Properties.TagsProperty } else { @{} }

            ########################################################################################################
            ######### CHECK PRIMARY-OWNER-EMAIL, PRIMARY-GROUP, ENVIRONMENT TAGS EXIST AND APPLY IF EMPTY ##########
            ########################################################################################################

            # Get the list of owners that are listed on the subscription, search for the owner role only
            $rbacOwners = Get-AzRoleAssignment -Scope "/subscriptions/$($uniqueSubscription.Id)" -RoleDefinitionId "8e3af657-a8ff-443c-a75c-2fe8c4bcb635" # this is the id for OWNER role
            $rbacUniqueOwners = $rbacOwners | Select-Object SignInName, ObjectType -Unique | Where-Object { $_.ObjectType -ne "ServicePrincipal" -and $_.SignInName -notmatch $adminDomainEmailToIgnoreRBAC}
            # This strips out the pure tenant level users i.e. Global Admins and just leaves the primary domain accounts as owners
            
            If($rbacUniqueOwners) { # Check if any non-admin users are associated as owners
                $primaryOwnerEmail = $rbacUniqueOwners.SignInName.ToLower() -join ";"
            }
            Else { # Put in catch incase their are no owners that aren't admins
                #If(!$primaryOwnerEmail){ $primaryOwnerEmail = "$RBACAdminEmail" }
                $primaryOwnerEmail = "$RBACAdminEmail"
            }


            #######################################################################################################
            ## Check for existing SUBSCRIPTION LEVEL 'primary-owner-email' tag and overwrite if empty or not match, or skip if identical

            If (($null -eq $currentTags) -or !$currentTags.ContainsKey($tagNamePrimaryOwnerEmail)) { # If NO primary-owner-email tag exists then add it
       	        Write-Output "Subscription Level: Adding '$tagNamePrimaryOwnerEmail' tag to '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' with '$primaryOwnerEmail'"
                # Need to create the new tag and add the value...
                $insertNewTagPrimaryOwnerEmail = @{ $tagNamePrimaryOwnerEmail = $primaryOwnerEmail }
                Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $insertNewTagPrimaryOwnerEmail -Operation Merge | Out-Null
            }
            ElseIf ($currentTags["$tagNamePrimaryOwnerEmail"] -ne $primaryOwnerEmail) # If tag exists but does not match, then check and maybe overwrite
            {
                # If the current tag is different from the generated template email then skip. Rather have a 'real' user than a placeholder
                If ($primaryOwnerEmail -eq $RBACAdminEmail) {
                    # Do Nothing, we don't want to overwrite a 'real' email address with the placeholder
                    Write-Output "Subscription Level: Leaving the 'primary-owner-email' tag as the existing tag value of '$($currentTags["$tagNamePrimaryOwnerEmail"])'"
                }
                Else { # This means the calculated email is NOT the same as the existing tag (and it also different from the placeholder)
       	            $currentTags["$tagNamePrimaryOwnerEmail"] = $primaryOwnerEmail
       	            Write-Output "Subscription Level: Updating existing '$tagNamePrimaryOwnerEmail' tag for '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' to '$primaryOwnerEmail'"
                    Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $currentTags -Operation Merge | Out-Null
                }
            }
            Else { # This means the tag exists and already matches the existing owners
                # Do nothing, the primary-owner-email tag is already identical for this subscription
                Write-Output "Subscription Level: $tagNamePrimaryOwnerEmail already matches $primaryOwnerEmail"
            }

            #######################################################################################################
            ## Check for existing SUBSCRIPTION LEVEL 'primary-group' tag and overwrite if empty or not match, or skip if identical

            If (($null -eq $currentTags) -or !$currentTags.ContainsKey($tagNamePrimaryGroup)) { # If NO primary-group tag exists then add it
       	        Write-Output "Subscription Level: Adding '$tagNamePrimaryGroup' tag to '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' with '$tagValuePrimaryGroup'"
                # Need to create the new tag and add the value...
                $insertNewTagPrimaryGroup = @{ $tagNamePrimaryGroup = $tagValuePrimaryGroup }
                Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $insertNewTagPrimaryGroup -Operation Merge | Out-Null
            }
            ElseIf ($currentTags["$tagNamePrimaryGroup"] -ne $tagValuePrimaryGroup) # If tag exists but does not match, then check and maybe overwrite
            {
	            $currentTags["$tagNamePrimaryGroup"] = $tagValuePrimaryGroup
       	        Write-Output "Subscription Level: Updating existing '$tagNamePrimaryGroup' tag for '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' to '$tagValuePrimaryGroup'"
                Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $currentTags -Operation Merge | Out-Null
                
            }
            Else { # This means the tag exists and already matches the existing owners
                # Do nothing, the primary-owner-email tag is already identical for this subscription
                Write-Output "Subscription Level: $tagNamePrimaryGroup already matches $tagValuePrimaryGroup"
            }

            #######################################################################################################
            ## Check for existing SUBSCRIPTION LEVEL 'environment' tag and overwrite if empty or not match, or skip if identical

            If (($null -eq $currentTags) -or !$currentTags.ContainsKey($tagNameEnvironment)) { # If NO primary-group tag exists then add it
       	        Write-Output "Subscription Level: Adding '$tagNameEnvironment' tag to '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' with '$tagValueEnvironment'"
                # Need to create the new tag and add the value...
                $insertNewTagEnvironment = @{ $tagNameEnvironment = $tagValueEnvironment }
                Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $insertNewTagEnvironment -Operation Merge | Out-Null
            }
            ElseIf ($currentTags["$tagNameEnvironment"] -ne $tagValueEnvironment) # If tag exists but does not match, then check and maybe overwrite
            {
	            $currentTags["$tagNameEnvironment"] = $tagValueEnvironment
       	        Write-Output "Subscription Level: Updating existing '$tagNameEnvironment' tag for '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' to '$tagValueEnvironment'"
                Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $currentTags -Operation Merge | Out-Null
                
            }
            Else { # This means the tag exists and already matches the existing owners
                # Do nothing, the primary-owner-email tag is already identical for this subscription
                Write-Output "Subscription Level: $tagNameEnvironment already matches $tagValueEnvironment"
            }

            ########################################################################################################
            ################ CHECK SUBSCRIPTION LEVEL RESOURCE-BUILD-DATE EXISTS AND APPLY IF EMPTY ################
            ########################################################################################################

            # Attempt to retrieve the creation date of the subscription. This is a close approximate based on the earliest flag that is set during creation. NOTE: The AZLog has a maximum log search of 90 days.
            # If it has been longer than 90 days, the next best approximation is to search for the earliest times of any resource group created and use the timestamp
            # If no resource group created, then leave tag empty, meaning it will be stamped with the UTC current date when it's moved into the new ManagementGroup structure.
           
            ##############################################################################
            ####### Check for the eventTimeStamp from the AZLog for the subscription (only allows up to 90 day search)
            $subscriptionInitialBuildAZLog = Get-AzLog -StartTime (Get-Date).AddDays(-90) -ResourceProvider "Microsoft.Subscription" | Select-Object OperationName, Status, EventTimeStamp  | Sort-Object { [datetime]$_.eventTimeStamp } | Select-Object -First 1
            If($subscriptionInitialBuildAZLog)
            {
                #$subscriptionInitialBuildAZLogFormattedDate = $subscriptionInitialBuildAZLog.EventTimestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                $subscriptionInitialBuildAZLogFormattedDate = Get-Date ($subscriptionInitialBuildAZLog.EventTimestamp) -Format "yyyy-MM-ddTHH:mm:ssZ"	
            }

            ##############################################################################
            ####### Check for the earliest created resource group within the Subscription group (i.e. NetworkWatcherRG or the vnet RG)
            $apiCheckForResourceGroupCreatedTime = "/subscriptions/$($uniqueSubscription.Id)/resourceGroups?`$expand=createdTime&api-version=2021-04-01" # Search the API and expand the 'createdTime' for any underlying resource groups
            $apiCheckForResourceGroupCreatedTimeResponse = Invoke-AzRestMethod -Method GET -Path $apiCheckForResourceGroupCreatedTime

            If($apiCheckForResourceGroupCreatedTimeResponse){
                # Parse through the returned JSON, sort by oldest, and select the earliest (first) resource group returned
                $resourceGroupReturnedJSON = ($apiCheckForResourceGroupCreatedTimeResponse.Content | ConvertFrom-Json).value
                If($resourceGroupReturnedJSON) {
                    $resourceGroupEarliestCreationTimestamp = $resourceGroupReturnedJSON | Select-Object createdTime | Sort-Object { [datetime]$_.createdTime } | Select-Object -First 1
                    #Convert the returned createdTime timestamp into the UTC format and store as $resourceGroupsEarliestCreationTimestampFormattedDate
                    #$resourceGroupEarliestCreationTimestampFormattedDate = $resourceGroupEarliestCreationTimestamp.CreatedTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    $resourceGroupEarliestCreationTimestampFormattedDate = Get-Date ($resourceGroupEarliestCreationTimestamp.CreatedTime) -Format "yyyy-MM-ddTHH:mm:ssZ"	
                }
                Else {
                    $resourceGroupEarliestCreationTimestampFormattedDate = "" # Leave empty, as it will be compared or calculated in the next section
                }
            }

            ###############################################################################################################################################
            # We now have checked for any AZLog version (>90 days ago) and the earliest created resource group version (if any RG has been created).
            # The AZLog has a delay in updating details so it might show the subscription creation date as being AFTER the underlying resource creation!.
            # To get a more accurate timestamp, we compare them both and choose the 'earliest' date to use for the rest of the script.
            ###############################################################################################################################################

            # If nothing was discovered in the AZLog (created over 90 days ago, BUT a Resource Group exists, then use the RG timestamp
            If(!$subscriptionInitialBuildAZLogFormattedDate -and $resourceGroupEarliestCreationTimestampFormattedDate) {
                #Write-output "$($uniqueSubscription.Id) ($($uniqueSubscription.Name)): Using 'CreatedTime' from oldest Resource Group (no date was discovered using AZLog)"
                $subscriptionInitialBuildFormattedDate = $resourceGroupEarliestCreationTimestampFormattedDate
            } # If an entry was discovered in the AZLog BUT no Resource Group exists, then use the AZLog stamp
            ElseIf($subscriptionInitialBuildAZLogFormattedDate -and !$resourceGroupEarliestCreationTimestampFormattedDate) {
                #Write-output "$($uniqueSubscription.Id) ($($uniqueSubscription.Name)): Using 'EventTimeStamp' retrieved from Get-AzLog (no resource groups have been created)" 
                $subscriptionInitialBuildFormattedDate = $subscriptionInitialBuildAZLogFormattedDate
            }  # This means values were retrieved from BOTH the AZLog AND Resource Group, so now compare the two and use the 'oldest' timestamp
            ElseIf ($subscriptionInitialBuildAZLogFormattedDate -and $resourceGroupEarliestCreationTimestampFormattedDate) {    
                If ($resourceGroupEarliestCreationTimestampFormattedDate -lt $subscriptionInitialBuildAZLogFormattedDate) {
                    #Write-Output "$($uniqueSubscription.Id) ($($uniqueSubscription.Name)): Using 'CreatedTime' from oldest Resource Group (contains older timestamp than AZLog)"
                    $subscriptionInitialBuildFormattedDate = $resourceGroupEarliestCreationTimestampFormattedDate
                }
                Else { # Both timestamps found, but AZLog version has an older timestamp, so use that
                    #Write-output "$($uniqueSubscription.Id) ($($uniqueSubscription.Name)): Using 'EventTimeStamp' retrieved from Get-AzLog (contains older timestamp than resource group data)"
                    $subscriptionInitialBuildFormattedDate = $subscriptionInitialBuildAZLogFormattedDate
                }
            } # This means that no AZLog OR ResourceGroup details exist so set as current UTC time
            ElseIf (!$subscriptionInitialBuildAZLogFormattedDate -and !$resourceGroupEarliestCreationTimestampFormattedDate) {
                #Write-Output "$($uniqueSubscription.Id) ($($uniqueSubscription.Name)): Neither 'EventTimeStamp' using AZLog or 'CreatedTime' from any Resource Group was found, using UTC"
                $subscriptionInitialBuildFormattedDate = Get-Date -UFormat "+%Y-%m-%dT%H:%M:%SZ"
            }

            ########################################################################################
            # The $subscriptionInitialBuildFormattedDate now contains the 'oldest' timestamp found, 
            # either from the Resource Group or from the AZLog.
            ########################################################################################

            # Check and compare the CURRENT tag for resource-build-date
            If (($null -eq $currentTags) -or !$currentTags.ContainsKey($tagNameResourceBuildDate)) { # If NO tags exist, or if the specific tag is not found then add it
                If($subscriptionInitialBuildFormattedDate) { # Will only add the tag if a pre-calculated timestamp exists
                    If($subscriptionInitialBuildFormattedDate -ne "") {
       	                Write-Output "Subscription Level: Adding '$tagNameResourceBuildDate' tag to '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' with '$subscriptionInitialBuildFormattedDate'"
                        $insertNewTagResourceBuildDate = @{ $tagNameResourceBuildDate = $subscriptionInitialBuildFormattedDate }
                        Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $insertNewTagResourceBuildDate -Operation Merge | Out-Null
                    }
                    Else {
                        Write-Output "Subscription Level: Unable to add '$tagNameResourceBuildDate' tag to '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' with '$subscriptionInitialBuildFormattedDate'"
                    }
                }
            } # If resource-build-date tag exists but does not match what has been pre-calculated, then keep the oldest timestamp
            ElseIf ($currentTags["$tagNameResourceBuildDate"] -ne $subscriptionInitialBuildFormattedDate) 
            { # If there are TWO different timestamp values, then compare for the 'oldest' one
		        If($subscriptionInitialBuildFormattedDate) {
                    If($subscriptionInitialBuildFormattedDate -ne "") {
                        If ($currentTags["$tagNameResourceBuildDate"] -lt $subscriptionInitialBuildFormattedDate) {
                        # If the current tag timestamp on the subscription is older (earlier) than the calculated version, which could have been from the next closest RG timestamp, then keep the current one
                            Write-Output "Subscription Level: Keeping existing '$tagNameResourceBuildDate' tag for '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' as '$($currentTags["$tagNameResourceBuildDate"])'" #`n(existing tag value is older than calculated date: $subscriptionInitialBuildFormattedDate)"
                            $subscriptionInitialBuildFormattedDate = $currentTags["$tagNameResourceBuildDate"]
                        } 
                        Else {
                            Write-Output "Subscription Level: Updating existing '$tagNameResourceBuildDate' tag for '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' with '$subscriptionInitialBuildFormattedDate'" #`n(existing tag value had a more recent/newer timestamp: $($currentTags["$tagNameResourceBuildDate"]))"
                        }            
                        # Then assign the resource-build-date tag to be whatever the calculated createdTimeStamp date is (even if it worked out to be the same as the current value)
                        $currentTags["$tagNameResourceBuildDate"] = $subscriptionInitialBuildFormattedDate
                        Update-AzTag -ResourceId "/subscriptions/$($uniqueSubscription.Id)" -Tag $currentTags -Operation Merge | Out-Null
                    }
                    Else {
                        Write-Output "Subscription Level: Unable to add '$tagNameResourceBuildDate' tag to '$($uniqueSubscription.id)' ($($uniqueSubscription.Name)) in '$($subscriptionManagementGroup.Name)' with '$subscriptionInitialBuildFormattedDate'"
                    }
                }
            }
            ElseIf ($currentTags["$tagNameResourceBuildDate"] -eq $subscriptionInitialBuildFormattedDate)  { # This means the tag exists and already matches the existing owners
                Write-Output "Subscription Level: $tagNameResourceBuildDate already matches $subscriptionInitialBuildFormattedDate"
                # Do nothing, the resource-build-date tag is already identical for this subscription
            }
            Else { # Error / Warning as a catch-all
                Write-Error "Subscription Level: WARNING - Subscription creation date could not be validated"
            }

            ########################################################################################################
            ############## CHECK RESOURCE GROUP LEVEL RESOURCE-BUILD-DATE EXISTS AND APPLY IF EMPTY ################
            ########################################################################################################

            $uniqueResourceGroup = ""
            $resourceGroupsInSubscription = ""
            $apiResourceGroupPath = ""
            $resourceGroupPathResponse = ""
            $resourceGroupReturnedData = ""

            # Get all resource groups in the current subscription scope, for subscriptions that are ENABLED (you can not write a disabled subscription)
            $resourceGroupsInSubscription = Get-AzResourceGroup

            If($resourceGroupsInSubscription)  # We only can stamp a tag on an Active/Enabled Subscription that HAS a resource group
	        {
                $apiResourceGroupPath = "/subscriptions/$($uniqueSubscription.id)/resourcegroups?api-version=2021-04-01&`$expand=createdTime"
		        $resourceGroupPathResponse = Invoke-AzRestMethod -Path $apiResourceGroupPath -Method GET

		        #This builds the temp list of ALL resourceGroups in the subscription, with JUST their name, id and createdTime
		        $resourceGroupReturnedData = ($resourceGroupPathResponse.Content | ConvertFrom-Json).value | Select-Object Name, id, createdTime

		        ForEach ($uniqueResourceGroup in $resourceGroupsInSubscription) {

			        $uniqueResourceGroupData = ""
			        $uniqueResourceGroupCreatedTime = ""
			        $uniqueResourceGroupFormattedDate = ""
			        $uniqueResourceGroupResourceTags = ""

                    $insertNewResourceGroupTagPrimaryOwnerEmail = ""
                    $insertNewResourceGroupTagPrimaryGroup = ""
                    $insertNewResourceGroupTagEnvironment = ""


                    #######################################################################################################
                    ## Check for existing RESOURCE GROUP LEVEL 'primary-owner-email' tag and overwrite if empty or not match, or skip if identical

                    If (($null -eq $uniqueResourceGroup.Tags) -or !$uniqueResourceGroup.Tags.ContainsKey($tagNamePrimaryOwnerEmail)) { # If NO primary-owner-email tag exists then add it
       	                Write-Output "Resource Group Level: Tagging '$tagNamePrimaryOwnerEmail' tag in '$($uniqueResourceGroup.ResourceGroupName)' with '$primaryOwnerEmail'"                    
                        # Need to create the new tag and add the value...
                        $insertNewResourceGroupTagPrimaryOwnerEmail = @{ $tagNamePrimaryOwnerEmail = $primaryOwnerEmail }
                        Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $insertNewResourceGroupTagPrimaryOwnerEmail -Operation Merge | Out-Null
                    }
                    ElseIf ($uniqueResourceGroup.Tags["$tagNamePrimaryOwnerEmail"] -ne $primaryOwnerEmail) # If tag exists but does not match, then check and maybe overwrite
                    {
       	                $uniqueResourceGroup.Tags["$tagNamePrimaryOwnerEmail"] = $primaryOwnerEmail
       	                Write-Output "Resource Group Level: Updating existing '$tagNamePrimaryOwnerEmail' tag in '$($uniqueResourceGroup.ResourceGroupName)' with '$primaryOwnerEmail'" 
                        Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $uniqueResourceGroup.Tags -Operation Merge | Out-Null       
                    }
                    Else { # This means the tag exists and already matches the existing owners
                        # Do nothing, the primary-owner-email tag is already identical for this subscription
                        Write-Output "Resource Group Level: '$($uniqueResourceGroup.ResourceGroupName)' $tagNamePrimaryOwnerEmail already matches $primaryOwnerEmail"
                    }

                    #######################################################################################################
                    ## Check for existing RESOURCE GROUP LEVEL 'primary-group' tag and overwrite if empty or not match, or skip if identical

                    If (($null -eq $uniqueResourceGroup.Tags) -or !$uniqueResourceGroup.Tags.ContainsKey($tagNamePrimaryGroup)) { # If NO primary-group tag exists then add it
       	                Write-Output "Resource Group Level: Tagging '$tagNamePrimaryGroup' tag in '$($uniqueResourceGroup.ResourceGroupName)' with '$tagValuePrimaryGroup'"                    
                        # Need to create the new tag and add the value...
                        $insertNewResourceGroupTagPrimaryGroup = @{ $tagNamePrimaryGroup = $tagValuePrimaryGroup }
                        Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $insertNewResourceGroupTagPrimaryGroup -Operation Merge | Out-Null
                    }
                    ElseIf ($uniqueResourceGroup.Tags["$tagNamePrimaryGroup"] -ne $tagValuePrimaryGroup) # If tag exists but does not match, then check and maybe overwrite
                    {
       	                $uniqueResourceGroup.Tags["$tagNamePrimaryGroup"] = $tagValuePrimaryGroup
       	                Write-Output "Resource Group Level: Updating existing '$tagNamePrimaryGroup' tag in '$($uniqueResourceGroup.ResourceGroupName)' with '$tagValuePrimaryGroup'" 
                        Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $uniqueResourceGroup.Tags -Operation Merge | Out-Null       
                    }
                    Else { # This means the tag exists and already matches the existing owners
                        # Do nothing, the primary-owner-email tag is already identical for this subscription
                        Write-Output "Resource Group Level: '$($uniqueResourceGroup.ResourceGroupName)' $tagNamePrimaryGroup already matches $tagValuePrimaryGroup"
                    }

                    #######################################################################################################
                    ## Check for existing RESOURCE GROUP LEVEL 'environment' tag and overwrite if empty or not match, or skip if identical

                    If (($null -eq $uniqueResourceGroup.Tags) -or !$uniqueResourceGroup.Tags.ContainsKey($tagNameEnvironment)) { # If NO environment tag exists then add it
       	                Write-Output "Resource Group Level: Tagging '$tagNameEnvironment' tag in '$($uniqueResourceGroup.ResourceGroupName)' with '$tagValueEnvironment'"                    
                        # Need to create the new tag and add the value...
                        $insertNewResourceGroupTagEnvironment = @{ $tagNameEnvironment = $tagValueEnvironment }
                        Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $insertNewResourceGroupTagEnvironment -Operation Merge | Out-Null
                    }
                    ElseIf ($uniqueResourceGroup.Tags["$tagNameEnvironment"] -ne $tagValueEnvironment) # If tag exists but does not match, then check and maybe overwrite
                    {
       	                $uniqueResourceGroup.Tags["$tagNameEnvironment"] = $tagValueEnvironment
       	                Write-Output "Resource Group Level: Updating existing '$tagNameEnvironment' tag in '$($uniqueResourceGroup.ResourceGroupName)' with '$tagValueEnvironment'" 
                        Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $uniqueResourceGroup.Tags -Operation Merge | Out-Null       
                    }
                    Else { # This means the tag exists and already matches the existing owners
                        # Do nothing, the primary-owner-email tag is already identical for this subscription
                        Write-Output "Resource Group Level: '$($uniqueResourceGroup.ResourceGroupName)' $tagNameEnvironment already matches $tagValueEnvironment"
                    }


                    #######################################################################################################
                    ## Check for existing RESOURCE GROUP LEVEL 'resource-build-date' tag and overwrite if empty or not match, or skip if identical

                    # Check if the tag already exists to avoid redundant writes
			        If ($null -eq $uniqueResourceGroup.Tags -or !$uniqueResourceGroup.Tags.ContainsKey($tagNameResourceBuildDate)) {
				
				        # Retrieves the details (name, id, createdTime) of JUST the resourceGroup name its currently validating
                        $uniqueResourceGroupData = $resourceGroupReturnedData | Where-Object id -eq "$($uniqueResourceGroup.ResourceId)"
				        # Pull out the specific createdTime from that list
				        $uniqueResourceGroupCreatedTime = $uniqueResourceGroupData.CreatedTime
     
				        If ($uniqueResourceGroupCreatedTime) # If a historical timestamp was found then format and tag
                        { 
					        # Convert the time to UTC format 
                            Try {  
                                $uniqueResourceGroupFormattedDate = Get-Date ($uniqueResourceGroupData.CreatedTime) -Format "yyyy-MM-ddTHH:mm:ssZ"	
                            }	    
					        Catch {
                                 Write-Output "Resource Group Level: Tagging '$($uniqueSubscription.Name)' ToString() backfill '$($uniqueResourceGroup.ResourceGroupName)' with '$tagNameResourceBuildDate' $uniqueResourceGroupFormattedDate"
                                 $uniqueResourceGroupFormattedDate = $uniqueResourceGroupCreatedTime.ToString("yyyy-MM-ddTHH:mm:ssZ")	
                            }			
					        # Prepare the tag payload
					        $uniqueResourceGroupResourceTags = $uniqueResourceGroup.Tags
					        if ($null -eq $uniqueResourceGroupResourceTags) { $uniqueResourceGroupResourceTags = @{} }
					        $uniqueResourceGroupResourceTags["$tagNameResourceBuildDate"] = $uniqueResourceGroupFormattedDate
					
					        Write-Output "Resource Group Level: Tagging '$($uniqueSubscription.Name)' historical backfill '$($uniqueResourceGroup.ResourceGroupName)' with '$tagNameResourceBuildDate' $uniqueResourceGroupFormattedDate"
					        Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $uniqueResourceGroupResourceTags -Operation Merge | Out-Null
				        } 
                        Else 
                        { 
                            Write-Error "Resource Group Level: WARNING - No historial createdTime stamp was recoverable for '$($uniqueResourceGroup.ResourceGroupName)'"
                        }
			        } 
                    ElseIF ($uniqueResourceGroup.Tags.ContainsKey("$tagNameResourceBuildDate")) { # If the resource-build-date tag EXISTS but the date does not match then overwrite
                     
                        $currentTagDateValue = ""
                        $currentTagDateValue = $($uniqueResourceGroup.Tags)."$tagNameResourceBuildDate"   
                    
                        # Retrieves the details (name, id, createdTime) of JUST the resourceGroup name its currently validating
                        $uniqueResourceGroupData = $resourceGroupReturnedData | Where-Object id -eq "$($uniqueResourceGroup.ResourceId)"

                        # Pull out the specific createdTime from that list
                        $uniqueResourceGroupCreatedTime = $uniqueResourceGroupData.CreatedTime
                    
                        If ($uniqueResourceGroupCreatedTime) # If a historical timestamp was found then format and tag
                        { 
					        # Convert the time to UTC format 
                            Try {                        
                                $uniqueResourceGroupFormattedDate = Get-Date ($uniqueResourceGroupData.CreatedTime) -Format "yyyy-MM-ddTHH:mm:ssZ"	
                            }
                            Catch {
                                 Write-Output "Resource Group Level: Tagging '$($uniqueSubscription.Name)' ToString() backfill '$($uniqueResourceGroup.ResourceGroupName)' with '$tagNameResourceBuildDate' $uniqueResourceGroupFormattedDate"
                                 $uniqueResourceGroupFormattedDate = $uniqueResourceGroupCreatedTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                            } 
                            
                            ######################################################################################################################
                            # Check if the retrieved data from the JSON matches the tag on the resourceGroup (to see if it was modified manually)
                            ######################################################################################################################
                            
                            If($uniqueResourceGroupFormattedDate -ne ($($uniqueResourceGroup.Tags)."$tagNameResourceBuildDate"))
                            {
                                If(!$currentTagDateValue) { $currentTagDateValue = "Empty" }
                                #Write-Output "Resource Group Level: Tag '$tagNameResourceBuildDate' for $($uniqueResourceGroup.ResourceGroupName) does not match.`nAttempting to set from $currentTagDateValue to $uniqueResourceGroupFormattedDate"
                                # Prepare the tag payload
					            $uniqueResourceGroupResourceTags = $uniqueResourceGroup.Tags
					            If ($null -eq $uniqueResourceGroupResourceTags) { $uniqueResourceGroupResourceTags = @{} }			
					            Try {	
					                $uniqueResourceGroupResourceTags["$tagNameResourceBuildDate"] = $uniqueResourceGroupFormattedDate # FormattedDate is the converted timestamp (yyyy-MM-ddTHH:mm:ssZ)
                                    Write-Output "Resource Group Level: Overwriting existing '$tagNameResourceBuildDate' tag for '$($uniqueResourceGroup.ResourceGroupName)' with historical backfill of $uniqueResourceGroupFormattedDate"
                                    Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $uniqueResourceGroupResourceTags -Operation Merge | Out-Null
                                }
                                Catch {
                                    $uniqueResourceGroupResourceTags["$tagNameResourceBuildDate"] = $uniqueResourceGroupCreatedTime # CreatedTime is the timestamp in the original format (fail-back)
                                    Write-Output "Resource Group Level: Overwriting existing '$tagNameResourceBuildDate' tag for '$($uniqueResourceGroup.ResourceGroupName)' with unformatted backfill timestamp of $uniqueResourceGroupCreatedTime"
                                    Update-AzTag -ResourceId $uniqueResourceGroup.ResourceId -Tag $uniqueResourceGroupResourceTags -Operation Merge | Out-Null
                                }
                            }
                            Else { 
                                Write-Output "Resource Group Level: '$($uniqueResourceGroup.ResourceGroupName)' $tagNameResourceBuildDate tag already matches $uniqueResourceGroupFormattedDate"
                            }
                        }
                        Else { Write-Error "Resource Group Level: WARNING - Unable to set Tag '$tagNameResourceBuildDate' for $($uniqueResourceGroup.ResourceGroupName)"}
                    }
		        }
	        } Else { }#Write-Output "No resource group found in '$($uniqueSubscription.DisplayName)'"}

            ########################################################################################################
            ################## CHECK RESOURCE LEVEL RESOURCE-BUILD-DATE EXISTS AND APPLY IF EMPTY ##################
            ########################################################################################################

            $uniqueResources = ""
            $ResourcesInSubscription = ""
            $apiResourcesPath = ""
            $ResourcesPathResponse = ""
            $ResourcesReturnedData = ""

            # Get all resources in the current subscription scope, for subscriptions that are ENABLED (you can not write a disabled subscription)
            $ResourcesInSubscription = Get-AzResource
	    
	        If($ResourcesInSubscription) # We only can stamp a tag on an Active/Enabled Subscription that HAS resources
	        {
		        # Have to use Invoke-AzRestMethod to get ALL Resourcess within that subscription
		        $apiResourcesPath = "/subscriptions/$($uniqueSubscription.id)/Resources?api-version=2021-04-01&`$expand=createdTime"
		        $ResourcesPathResponse = Invoke-AzRestMethod -Path $apiResourcesPath -Method GET

		        #This builds the temp list of ALL Resourcess in the subscription, with JUST their name, id and createdTime
		        $ResourcesReturnedData = ($ResourcesPathResponse.Content | ConvertFrom-Json).value | Select-Object Name, id, createdTime

		        ForEach ($uniqueResources in $ResourcesInSubscription) {

			        $uniqueResourcesData = ""
			        $uniqueResourcesCreatedTime = ""
			        $uniqueResourcesFormattedDate = ""
			        $uniqueResourcesResourceTags = ""

                    $insertNewResourcesTagPrimaryOwnerEmail = ""
                    $insertNewResourcesTagPrimaryGroup = ""
                    $insertNewResourcesTagEnvironment = ""


                    #######################################################################################################
                    ## Check for existing RESOURCE LEVEL 'primary-owner-email' tag and overwrite if empty or not match, or skip if identical

                    If (($null -eq $uniqueResources.Tags) -or !$uniqueResources.Tags.ContainsKey($tagNamePrimaryOwnerEmail)) { # If NO primary-owner-email tag exists then add it
       	                Write-Output "Resource Level: Tagging '$tagNamePrimaryOwnerEmail' tag in '$($uniqueResources.ResourceName)' with '$primaryOwnerEmail'"                    
                        # Need to create the new tag and add the value...
                        $insertNewResourcesTagPrimaryOwnerEmail = @{ $tagNamePrimaryOwnerEmail = $primaryOwnerEmail }
                        Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $insertNewResourcesTagPrimaryOwnerEmail -Operation Merge | Out-Null
                    }
                    ElseIf ($uniqueResources.Tags["$tagNamePrimaryOwnerEmail"] -ne $primaryOwnerEmail) # If tag exists but does not match, then check and maybe overwrite
                    {
       	                $uniqueResources.Tags["$tagNamePrimaryOwnerEmail"] = $primaryOwnerEmail
       	                Write-Output "Resource Level: Updating existing '$tagNamePrimaryOwnerEmail' tag in '$($uniqueResources.ResourceName)' with '$primaryOwnerEmail'" 
                        Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $uniqueResources.Tags -Operation Merge | Out-Null       
                    }
                    Else { # This means the tag exists and already matches the existing owners
                        # Do nothing, the primary-owner-email tag is already identical for this resource
                        Write-Output "Resource Level: '$($uniqueResources.ResourceName)' $tagNamePrimaryOwnerEmail already matches $primaryOwnerEmail"
                    }

                    #######################################################################################################
                    ## Check for existing RESOURCE LEVEL 'primary-group' tag and overwrite if empty or not match, or skip if identical

                    If (($null -eq $uniqueResources.Tags) -or !$uniqueResources.Tags.ContainsKey($tagNamePrimaryGroup)) { # If NO primary-group tag exists then add it
       	                Write-Output "Resource Level: Tagging '$tagNamePrimaryGroup' tag in '$($uniqueResources.ResourceName)' with '$tagValuePrimaryGroup'"                    
                        # Need to create the new tag and add the value...
                        $insertNewResourcesTagPrimaryGroup = @{ $tagNamePrimaryGroup = $tagValuePrimaryGroup }
                        Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $insertNewResourcesTagPrimaryGroup -Operation Merge | Out-Null
                    }
                    ElseIf ($uniqueResources.Tags["$tagNamePrimaryGroup"] -ne $tagValuePrimaryGroup) # If tag exists but does not match, then check and maybe overwrite
                    {
       	                $uniqueResources.Tags["$tagNamePrimaryGroup"] = $tagValuePrimaryGroup
       	                Write-Output "Resource Level: Updating existing '$tagNamePrimaryGroup' tag in '$($uniqueResources.ResourceName)' with '$tagValuePrimaryGroup'" 
                        Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $uniqueResources.Tags -Operation Merge | Out-Null       
                    }
                    Else { # This means the tag exists and already matches the existing owners
                        # Do nothing, the primary-owner-email tag is already identical for this resource
                        Write-Output "Resource Level: '$($uniqueResources.ResourceName)' $tagNamePrimaryGroup already matches $tagValuePrimaryGroup"
                    }

                    #######################################################################################################
                    ## Check for existing RESOURCE LEVEL 'environment' tag and overwrite if empty or not match, or skip if identical

                    If (($null -eq $uniqueResources.Tags) -or !$uniqueResources.Tags.ContainsKey($tagNameEnvironment)) { # If NO environment tag exists then add it
       	                Write-Output "Resource Level: Tagging '$tagNameEnvironment' tag in '$($uniqueResources.ResourceName)' with '$tagValueEnvironment'"                    
                        # Need to create the new tag and add the value...
                        $insertNewResourcesTagEnvironment = @{ $tagNameEnvironment = $tagValueEnvironment }
                        Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $insertNewResourcesTagEnvironment -Operation Merge | Out-Null
                    }
                    ElseIf ($uniqueResources.Tags["$tagNameEnvironment"] -ne $tagValueEnvironment) # If tag exists but does not match, then check and maybe overwrite
                    {
       	                $uniqueResources.Tags["$tagNameEnvironment"] = $tagValueEnvironment
       	                Write-Output "Resource Level: Updating existing '$tagNameEnvironment' tag in '$($uniqueResources.ResourceName)' with '$tagValueEnvironment'" 
                        Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $uniqueResources.Tags -Operation Merge | Out-Null       
                    }
                    Else { # This means the tag exists and already matches the existing owners
                        # Do nothing, the primary-owner-email tag is already identical for this resource
                        Write-Output "Resource Level: '$($uniqueResources.ResourceName)' $tagNameEnvironment already matches $tagValueEnvironment"
                    }

                    #######################################################################################################
                    ## Check for existing RESOURCE LEVEL 'resource-build-date' tag and overwrite if empty or not match, or skip if identical

			        # Check if the tag already exists to avoid redundant writes
			        If ($null -eq $uniqueResources.Tags -or !$uniqueResources.Tags.ContainsKey("$tagNameResourceBuildDate")) {
				
				        # Retrieves the details (name, id, createdTime) of JUST the Resources name its currently validating
                        $uniqueResourcesData = $ResourcesReturnedData | Where-Object id -eq "$($uniqueResources.ResourceId)"
				        # Pull out the specific createdTime from that list
				        $uniqueResourcesCreatedTime = $uniqueResourcesData.CreatedTime
     
				        If ($uniqueResourcesCreatedTime) # If a historical timestamp was found then format and tag
                        { 
					        # Convert the time to UTC format 
                            Try {  
                                $uniqueResourcesFormattedDate = Get-Date ($uniqueResourcesData.CreatedTime) -Format "yyyy-MM-ddTHH:mm:ssZ"		
                            }
                            Catch {
                                 Write-Output "Resource Level: Tagging '$($uniqueSubscription.Name)' ToString() backfill '$($uniqueResources.ResourceName)' with '$tagNameResourceBuildDate' $uniqueResourcesFormattedDate"
                                 $uniqueResourcesFormattedDate = $uniqueResourcesCreatedTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                            }					    
                            # Prepare the tag payload
					        $uniqueResourcesResourceTags = $uniqueResources.Tags
					        if ($null -eq $uniqueResourcesResourceTags) { $uniqueResourcesResourceTags = @{} }
					        $uniqueResourcesResourceTags["$tagNameResourceBuildDate"] = $uniqueResourcesFormattedDate

					        Write-Output "Resource Level: Tagging '$($uniqueSubscription.Name)' historical backfill '$($uniqueResources.ResourceName)' with '$tagNameResourceBuildDate' $uniqueResourcesFormattedDate"
					        Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $uniqueResourcesResourceTags -Operation Merge | Out-Null
				        } 
                        Else 
                        { 
                            Write-Error "Resource Level: WARNING - No historial createdTime stamp was recoverable for '$($uniqueResources.ResourceName)'"
                        }
			        } ElseIF ($uniqueResources.Tags.ContainsKey("$tagNameResourceBuildDate")) { # If the resource-build-date tag EXISTS but the date does not match then overwrite
                     
                        $currentResourceTagDateValue = ""
                        $currentResourceTagDateValue = $($uniqueResources.Tags)."$tagNameResourceBuildDate"
                    
                        # Retrieves the details (name, id, createdTime) of JUST the Resources name its currently validating
                        $uniqueResourcesData = $ResourcesReturnedData | Where-Object id -eq "$($uniqueResources.ResourceId)"

                        # Pull out the specific createdTime from that list
                        $uniqueResourcesCreatedTime = $uniqueResourcesData.CreatedTime

                        If ($uniqueResourcesCreatedTime) # If a historical timestamp was found then format and tag
                        { 
					        # Convert the time to UTC format 
                            Try {  	
                                $uniqueResourcesFormattedDate = Get-Date ($uniqueResourcesData.CreatedTime) -Format "yyyy-MM-ddTHH:mm:ssZ"		
                            }
                            Catch {
                                 Write-Output "Resource Level: Tagging '$($uniqueSubscription.Name)' ToString() backfill '$($uniqueResources.ResourceName)' with '$tagNameResourceBuildDate' $uniqueResourcesFormattedDate"
                                 $uniqueResourcesFormattedDate = $uniqueResourcesCreatedTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                            } 
                            
                            #########################################################
                            # Check if the retrieved data from the JSON matches the tag on the resource (to see if it was modified manually)
                            #########################################################

                            If($uniqueResourcesFormattedDate -ne ($($uniqueResources.Tags)."$tagNameResourceBuildDate"))
                            {
                                If(!$currentResourceTagDateValue) { $currentResourceTagDateValue = "Empty" }
                                #Write-Output "Resource Level: Tag 'resource-build-date' for $($uniqueResources.ResourceName) [$($uniqueResources.ResourceId)] does not match.`nAttempting to set from $currentResourceTagDateValue back to $uniqueResourcesFormattedDate"
                                # Prepare the tag payload
					            $uniqueResourcesResourceTags = $uniqueResources.Tags
					            If ($null -eq $uniqueResourcesResourceTags) { $uniqueResourcesResourceTags = @{} }
					            Try {					    
					        	    $uniqueResourcesResourceTags["$tagNameResourceBuildDate"] = $uniqueResourcesFormattedDate # FormattedDate is the converted timestamp (yyyy-MM-ddTHH:mm:ssZ)
                                    Write-Output "Resource Level: Overwriting existing '$tagNameResourceBuildDate' tag for '$($uniqueResources.ResourceName)' with historical backfill of $uniqueResourcesFormattedDate"                          
                                    Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $uniqueResourcesResourceTags -Operation Merge | Out-Null                                                  
                                }
                                Catch {
                                    $uniqueResourcesResourceTags["$tagNameResourceBuildDate"] = $uniqueResourcesCreatedTime # CreatedTime is the timestamp in the original format (fail-back)
                                    Write-Output "Resource Level: Overwriting existing '$tagNameResourceBuildDate' tag for '$($uniqueResources.ResourceName)' with unformatted backfill timestamp of $uniqueResourcesCreatedTime"
                                    Update-AzTag -ResourceId $uniqueResources.ResourceId -Tag $uniqueResourcesResourceTags -Operation Merge | Out-Null
                                }
                            }
                            Else { 
                                Write-Output "Resource Level: '$($uniqueResources.ResourceName)' $tagNameResourceBuildDate tag already matches $uniqueResourcesFormattedDate"
                            }
                        }
                        Else { Write-Error "Resource Level: WARNING - Unable to set Tag '$tagNameResourceBuildDate' for '$($uniqueResources.ResourceName)'"}
		            }
                }
	        } Else { } #Write-Output "No resources found in '$($uniqueSubscription.DisplayName)'"}

            ########################################################################################################
            ############################ CHECK SUBSCRIPTION LOCATION AND MOVE IF NEEDED ############################
            ########################################################################################################

            # If the state is enabled BUT the subscription is already in the ENABLED MG, then just leave alone...
            If($($subscriptionManagementGroup.Name) -eq $enabledManagementGroupName){
                # Do nothing - the enabled subscription is already in the enabled MG
            }
            Else { # This means the subscription is ENABLED and needs to be moved to the enabled MG
                Write-Output "Migration Status: $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)' ... moving to '$enabledManagementGroupName'"
                Try {
                New-AzManagementGroupSubscription -GroupID $enabledManagementGroupName -SubscriptionId $($uniqueSubscription.Id) -ErrorAction Stop | Out-Null
                Write-Output "Successfully moved $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' from '$($subscriptionManagementGroup.Name)' to '$enabledManagementGroupName'"
                }
                Catch {
                    Write-Error "WARNING - Failed to move $($uniqueSubscription.Id) ($($uniqueSubscription.Name)) from '$($subscriptionManagementGroup.Name)' because: $_"
                }
            }
        } # This is the end of the ElseIf ($($uniqueSubscription.State) -eq "Enabled") statement
        Else { # If the state is anything other than Enabled or Disabled then just warn and leave it for manual intervention
            Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' from '$($subscriptionManagementGroup.Name)' has a state of: '$($uniqueSubscription.State)'... Skipping"
        }
        $uniqueSubscriptionIndex++ # Increase the number for the screen display to keep tally of which subscription number is being processed
    } # This is the end of the If($uniqueSubscription), means subscription was found... If not found then it moves to the next one in the list
} # This is the end of the ForEach loop that goes through each subscription

$timestampAfter = get-date -format yyyyMMdd:hh_mm_ssz
Write-Output "`nStart:`t[$timestamp]`nFinish:`t[$timestampAfter]`nScan complete. Parsed $($subscriptions.Count) subscription(s)..."