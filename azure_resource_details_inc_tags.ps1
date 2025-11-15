#*******************************************************************************
#************** RESOURCE DETAILS INCLUDING TAGS
#*******************************************************************************
 
$resources = @()
Get-AzSubscription | ForEach-Object {
    $_ | Set-AzContext
    $subscriptionName = $_.Name
    $subscriptionId = $_.SubscriptionId
    Get-AzResource | ForEach-Object {
        $resources += [PSCustomObject]@{
      		SubscriptionName  = $subscriptionName
            	SubscriptionId    = $subscriptionId
            	ResourceGroupName = $_.ResourceGroupName
            	ResourceName      = $_.ResourceName
            	ResourceType      = $_.ResourceType
            	Location          = $_.Location
		Tags		  = $_.Tags | ConvertTo-Json -compress
		ResourceId	  = $_.ResourceId
        } 		
    }
}
 
$resourcesDate = get-date -format _yyyy-MM-dd_
$resourcesTimestamp = get-date -UFormat "%H.%M.%S.%Z"
$resourcesSubscriptionNameTitle = $subscriptionName -replace " ","_"
$resourcesFinalStamp = $resourcesSubscriptionNameTitle+$resourcesDate+$resourcesTimestamp
$resources | Export-csv AllResources_$resourcesFinalStamp.csv -Append -NoTypeInformation

# If run from CloudShell, you can then use the Manage Files => Download option to save the file, or you can just change the Export-CSV location
