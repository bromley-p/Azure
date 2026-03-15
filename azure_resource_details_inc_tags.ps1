#************************************************
# RESOURCE DETAILS INCLUDING TAGS & VM SIZE TYPE
#************************************************

$resources = @()
$subscriptionName = ""
$subscriptionId = ""

# You can either have it check ALL subscriptions, or use a Where-Object to select particular subscriptions...
Get-AzSubscription | Where-Object {$_.Name -like "SubscriptionName1*" -OR $_.Name -like "SubscriptionName2*"} | ForEach-Object {
#Get-AzSubscription | ForEach-Object {
    $_ | Set-AzContext
    $subscriptionName = $_.Name
    $subscriptionId = $_.SubscriptionId
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

# If run from CloudShell, you can then use the Manage Files => Download option to save the file, or you can just change the Export-CSV location

