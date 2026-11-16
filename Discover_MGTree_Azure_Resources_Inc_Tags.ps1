#************************************************
# RESOURCE DETAILS INCLUDING TAGS & VM SIZE TYPE
#************************************************

#NOTE: This only returns details on RESOURCE types only. It does not return information on Subscriptions or Resource Groups.

$resources = @()
$subscriptionsInManagementGroups = ""
$discoveredSubscription = ""
$subscriptionName = ""
$subscriptionId = ""

##############################################################################################
# Edit the location of the MG here in order to start the search
##############################################################################################

$managementGroupTreeToSearch = "<insert the name of the management group that you want to search>"
# NOTE: It will also search any MG's nested underneath

##############################################################################################
# Edit the location of the MG here in order to start the search
##############################################################################################

Write-Output "`nThis script is being ran on the top management group '$managementGroupTreeToSearch' (and its child subscriptions)`n"

# Enter the ID of the TENANT ROOT GROUP
$managementGroup = "resourcecontainers | where type == 'microsoft.resources/subscriptions' | mv-expand managementGroupParent = properties.managementGroupAncestorsChain | where managementGroupParent.name =~ '$managementGroupTreeToSearch'"
$subscriptionsInManagementGroups = Search-AzGraph -Query $managementGroup

ForEach($discoveredSubscription in $subscriptionsInManagementGroups) {

    $subscriptionName = "$($discoveredSubscription.name)"
    $subscriptionId = "$($discoveredSubscription.subscriptionId)"

    Get-AzSubscription -subscriptionId "$($discoveredSubscription.subscriptionId)" | Set-AzContext | Out-Null
    Get-AzResource | ForEach-Object {
	     $vmSize = " "	
	     $vmSizeDetails = " "
	     $VMMemoryInGB = " "
          If($_.ResourceType -contains "Microsoft.Compute/virtualMachines"){
	         $vmSize = Get-AzVM -ResourceGroupName $_.ResourceGroupName -VMName $_.ResourceName  
          }
            $resources += [PSCustomObject]@{
      		    SubscriptionName  	= $subscriptionName
                SubscriptionId    	= $subscriptionId
                ResourceGroupName 	= $_.ResourceGroupName
                ResourceName      	= $_.ResourceName
                ResourceType      	= $_.ResourceType
			    VMSize		      	= $vmSize.HardwareProfile.VmSize
                Location          	= $_.Location
			    Tags		  		= $_.Tags | ConvertTo-Json -compress
			    ResourceId	  		= $_.ResourceId
            } 		
    }
}
 
$resourcesDate = get-date -format yyyy-MM-dd_
$resourcesTimestamp = get-date -UFormat "%H.%M.%S.%Z"
$resourcesFinalStamp = $resourcesDate+$resourcesTimestamp
$resources | Export-csv AllSubscriptionResources_$resourcesFinalStamp.csv -Append -NoTypeInformation
Write-output "******************************`nDisplaying first 10 results"
$resources | format-table -autosize | Select-Object -First 10

# If run from CloudShell, you can then use the Manage Files => Download option to save the file, or you can just change the Export-CSV location
Write-Output "`n`n=> Exported AllSubscriptionResources_$resourcesFinalStamp.csv`n" 