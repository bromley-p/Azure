Write-Output "Title: Runbook_CheckMultipleMG_move_subscriptions_based_on_state_change.ps1`nDate: YYYY-MM-DD`nDescription: Used to move subscriptions from '<Enabled Subscriptions MG>' and '<Disabled Subscriptions MG>' based on current state.`n"

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
$subscriptionsCombined = ""
$uniqueSubscriptionIndex = 1
$managementGroupArray = @()
$uniqueManagementGroup = ""
$timestamp = get-date -format yyyyMMdd:hh_mm_ssz

##########################################################################################
# EDIT THE NAMES OF THE MANAGEMENT GROUPS TO MATCH WHERE YOU WANT THEM TO BE MOVED
##########################################################################################

$disabledManagementGroupName = "<insert name of MG that contains disabled subscriptions>"
$enabledManagementGroupName = "<insert name of MG that contains enabled subscriptions>"

##########################################################################################
# EDIT THE NAMES OF THE MANAGEMENT GROUPS TO MATCH WHERE YOU WANT THEM TO BE MOVED
##########################################################################################

$managementGroupArray = @("$disabledManagementGroupName", "$enabledManagementGroupName")
$subscriptions = foreach ($uniqueManagementGroup in $managementGroupArray) { # Retrieve subscriptions for both management groups and combine them
    Get-AzManagementGroupSubscription -GroupID $uniqueManagementGroup  | Select-object -ExpandProperty Id | ForEach-Object { $_ -replace '.*/', '' } 
}

If(!$subscriptions -or ($subscriptions -eq "")){
	Write-Output "No subscriptions found in either '$disabledManagementGroupName' or '$enabledManagementGroupName'... exiting"
	Exit
} Else {
	Write-Output "[$timeStamp] Starting verification of $($subscriptions.Count) subscriptions in both '$disabledManagementGroupName' and '$enabledManagementGroupName'..."
}

ForEach ($uniqueGroupSubscription in $subscriptions) {
    
    $uniqueSubscription = ""
    $azGraphManagementGroupQuery = ""
    $subscriptionManagementGroup = ""

    #Set the context to the current subscription
	Try {
    	$uniqueSubscription = Get-AzSubscription -subscriptionID $uniqueGroupSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 
    	$null = Set-AzContext -SubscriptionId $($uniqueSubscription.Id) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null 
	} Catch {
		Write-Output "Not able to find subscription '$uniqueGroupSubscription'..."
		Continue
	}

    If($uniqueSubscription) { # Only checks on a valid, found subscription

        ##############################################################################
        ####### RETRIEVE THE MANAGEMENT GROUP LEVEL THE SUBSCRIPTION IS LOCATED ######
        $azGraphManagementGroupQuery = "resourcecontainers | where type == 'microsoft.resources/subscriptions' and subscriptionId == '$($uniqueSubscription.Id)' | project properties.managementGroupAncestorsChain"
        $subscriptionManagementGroup = (Search-AzGraph -Query $azGraphManagementGroupQuery).properties_managementGroupAncestorsChain[0] 

        ###################################################################
        ###################################################################
        # If the state of the Subscription is Enabled (Active), move to 'Enabled' Management Group (leave if already in the 'Enabled' MG)
        # If the state of the Subscription is Disabled / Warned, move to 'Disabled' Management Group (leave if already in the 'Disabled' MG)
         
        If ($($uniqueSubscription.State) -eq "Disabled" -or $($uniqueSubscription.State) -eq "Warned") { 
            # If the state is disabled (or Warned) BUT the subscription is already in the DISABLED MG, then just leave alone...
            If($($subscriptionManagementGroup.Name) -eq $disabledManagementGroupName){
                # Do nothing - the disabled/warned subscription is already in the disabled MG
                Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)' in '$disabledManagementGroupName'... Skipping"
            }
            Else { # This means the subscription is DISABLED and needs to be moved to the disabled MG
                Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)'... moving to '$disabledManagementGroupName'"
                Try {
                    New-AzManagementGroupSubscription -GroupID $disabledManagementGroupName -SubscriptionId $($uniqueSubscription.Id) -ErrorAction Stop | Out-Null
                    Write-Output "Successfully moved '$($uniqueSubscription.Id)' ($($uniqueSubscription.Name)) from '$($subscriptionManagementGroup.Name)' to '$disabledManagementGroupName'"
                }
                Catch {
                    Write-Error "Failed to move $($uniqueSubscription.Id) ($($uniqueSubscription.Name)) from '$($subscriptionManagementGroup.Name)' because: $_"
                }
            }
        }
        ElseIf ($($uniqueSubscription.State) -eq "Enabled") { # This means the Subscription is Active / Enabled so can be moved accordingly
            # If the state is enabled BUT the subscription is already in the Enabled MG, then just leave alone...
            If($($subscriptionManagementGroup.Name) -eq $enabledManagementGroupName){
                # Do nothing - the enabled subscription is already in the enabled MG
                Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)' in '$enabledManagementGroupName'... Skipping"
            }
            Else { # This means the subscription is ENABLED but NOT in the Enabled MG so it needs to be moved to the enabled MG
                Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' state is: '$($uniqueSubscription.State)'... moving to '$enabledManagementGroupName'"
                Try {
                 New-AzManagementGroupSubscription -GroupID $enabledManagementGroupName -SubscriptionId $($uniqueSubscription.Id) -ErrorAction Stop | Out-Null
                 Write-Output "Successfully moved $($uniqueSubscription.Id) ($($uniqueSubscription.Name)) from '$($subscriptionManagementGroup.Name)' to '$enabledManagementGroupName'"
                }
                Catch {
                    Write-Error "Failed to move $($uniqueSubscription.Id) ($($uniqueSubscription.Name)) from '$($subscriptionManagementGroup.Name)' because: $_"
                }
            }
        }
        Else { # If the state is anything other than Enabled or Disabled/Warned then just leave it for manual intervention
            Write-Output "$uniqueSubscriptionIndex) $($uniqueSubscription.Id) '$($uniqueSubscription.Name)' from '$($subscriptionManagementGroup.Name)' has a state of: '$($uniqueSubscription.State)'... Skipping"
        }
        $uniqueSubscriptionIndex++ # Increase the number for the screen display to keep tally of which subscription number is being processed
    }

} # This is the end of the ForEach loop that goes through each subscription

$timestampAfter = get-date -format yyyyMMdd:hh_mm_ssz
$uniqueSubscriptionIndex-- # This is because it adds a 'false' count to the end of the ForEach for the last subscription.
Write-Output "`nStart:`t[$timestamp]`nFinish:`t[$timestampAfter]`nScan complete. Parsed $uniqueSubscriptionIndex subscription(s)..."