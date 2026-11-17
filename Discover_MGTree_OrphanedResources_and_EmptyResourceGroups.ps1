$overallOrphanedDisks = @()
$overallOrphanedNIC = @()
$overallOrphanedNSG = @()
$overallOrphanedPIP = @()
$overallEmptyResourceGroupsList = @()
$summaryOverview = ""

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

    $subscriptionName = ""
    $subscriptionId = ""

    $subscriptionName = "$($discoveredSubscription.name)"
    $subscriptionId = "$($discoveredSubscription.subscriptionId)"
    
	$disk = ""
	$NICs = ""
	$NSGs = ""
	$publicIP = ""
	$orphanDisks = ""
	$orphanNIC = ""
	$orphanNSG = ""
	$orphanPIP = ""
    $discoveredResourceGroups = ""
    $discoveredResources = ""
    $uniqueEmptyResourceGroup = ""
    $overallEmptyResourceGroups = ""
	
    Get-AzSubscription -subscriptionId $subscriptionId | Set-AzContext | Out-Null
	
    ###################### DISCOVER DISK STORAGE ###################### 
	$disk = Get-AzDisk
	$orphanDisks = $disk | Select-Object -Property Name, ManagedBy, ResourceGroupName, Type, DiskSizeGB, DiskState | Where-Object { $_.DiskState -eq "Unattached"} # { $_.DiskState -eq "Reserved"}
	Foreach ($disks in $orphanDisks){ 

		$disksResourceGroup = ""
		$diskName = ""

	    $disksResourceGroup=$disks.ResourceGroupName.ToLower()
	    $diskName=$disks.Name.ToLower()
        If($disksResourceGroup)
        {
	        $overallOrphanedDisks += "`nUnattached DSK:`t$subscriptionName\$disksResourceGroup\$DiskName"
        }

        ############## CAUTION - THIS IS THE REMOVAL CODE ############## 
	            #$diskState=$disks.DiskState
 	            #Write-Host "Disk Name       : $diskName"
	            #Write-Host "ResourceGoupName: $disksResourceGroup"
	            #Write-Host "State           : $diskState"
	            #Write-Host ""
	            #Write-Host "Deleting unattached Managed Disk:$diskName"
	            #$disks | Remove-AzDisk -Force
	            #Write-Host "Managed Disk: $diskName Deleted!"
        ############## CAUTION - THIS IS THE REMOVAL CODE ############## 

	}

    ###################### DISCOVER NETWORK INTERFACE CARDS ###################### 
	$NICs = Get-AzNetworkInterface
	$orphanNIC = $NICS | Select-Object Name, ResourceGroupName, VirtualMachine | Where-Object { $_.VirtualMachine -eq $null }
	Foreach ($NIC in $orphanNIC){
		
		$NICName = ""
		$VMName = ""
		$NICResourceGroup = ""

		$NICName = $NIC.Name.ToLower()
	    $NICResourceGroup = $NIC.ResourceGroupName.ToLower()
        If($NICResourceGroup)
        {
	        $overallOrphanedNIC += "`nUnattached NIC:`t$subscriptionName\$NICResourceGroup\$NICName" #(VM: $($VMName.VMName))"
        }

        ############## CAUTION - THIS IS THE REMOVAL CODE ############## 
	            #Write-Host "NIC Name        : $NICName"
                #Write-Host "Resource Group  : $NICResourceGroup"
                #Write-Host "Deleting NIC: $NICName"
                #$NIC | Remove-AzNetworkInterface -Force
                #Write-Host "NIC: $NICName Deleted Successfully"
                #Write-Host ""
        ############## CAUTION - THIS IS THE REMOVAL CODE ############## 

	}

    ###################### DISCOVER NETWORK SECURITY GROUPS ###################### 
	$NSGs = Get-AzNetworkSecurityGroup
	$orphanNSG = $NSGs | Select-Object Name, ResourceGroupName, NetworkInterfaces | Where-Object { $_.NetworkInterfaces.count -eq 0}
	Foreach ($NSG in $orphanNSG){

		$NSGResourceGroup = ""
		$NSGName = ""

		$NSGResourceGroup = $NSG.ResourceGroupName.ToLower()
		$NSGName = $NSG.name.ToLower()
        If($NSGResourceGroup)
        {
		    $overallOrphanedNSG += "`nUnattached NSG:`t$subscriptionName\$NSGResourceGroup\$NSGName"
	    }

        ############## CAUTION - THIS IS THE REMOVAL CODE ############## 
		        #Write-Host "NSG Name        : $NSGName"
		        #Write-Host "ResourceGoupName: $NSGResourceGroup"
		        #Write-Host "Deleting NSG: $NSGName "
		        #$NSG | Remove-AzDisk -Force
		        #Write-Host "NSG: $NSGName Successfully Deleted"
        ############## CAUTION - THIS IS THE REMOVAL CODE ############## 

	}

    ###################### DISCOVER PUBLIC IP ADDRESSES ###################### 
	$publicIP = Get-AzPublicIpAddress | Where-Object {$_.IpConfiguration -eq $null -and $_.NatGateway -eq $null} 
	$orphanPIP = $publicIP | Select-Object Name, ResourceGroupName, IpAddress, Sku
	Foreach ($PIP in $orphanPIP){

		$PIPResourceGroup = ""
		$PIPIpAddress = ""
		$PIPName = ""

		$PIPResourceGroup=$PIP.ResourceGroupName.ToLower()
		$PIPIpAddress = $PIP.IpAddress.ToLower()
		$PIPName=$PIP.Name.ToLower()
        If($PIPResourceGroup)
        {
		    $overallOrphanedPIP += "`nUnattached PIP:`t$subscriptionName\$PIPResourceGroup\$PIPName (IP: $PIPIpAddress)"
	    }

		#Write-Host "PIP Name: $PIPName"
		#Write-Host "PIP IP Address: $PIPIpAddress"
		#Write-Host "ResourceGoupName: $PIPResourceGroup"
	}


    ###################### DISCOVER RESOURCE GROUPS ###################### 
    $discoveredResourceGroups = Get-AzResourceGroup
    $discoveredResources = (Get-AzResource | Group-Object ResourceGroupName).Name

    # Filter for resource groups with zero resources and then add to total
    $overallEmptyResourceGroups = $discoveredResourceGroups | Where-Object { $_.ResourceGroupName -notin $discoveredResources }
    ForEach($uniqueEmptyResourceGroup in $overallEmptyResourceGroups){
        $overallEmptyResourceGroupsList += "`n$subscriptionName\$($uniqueEmptyResourceGroup.ResourceGroupName)"
    }
}

# Generate a summary of the orphaned resources and the empty resource groups - also save to file

$summaryOverview = "`n****************** SUMMARY ******************`n`nUnattached Disks: $($overallOrphanedDisks.count)`nUnattached NICs: $($overallOrphanedNIC.count)`nUnattached NSGs: $($overallOrphanedNSG.count)`nUnattached PIPs: $($overallOrphanedPIP.count)`nEmpty ResourceGroups: $($overallEmptyResourceGroupsList.count)"
$summaryOverview

If(!$overallOrphanedDisks){ $overallOrphanedDisks = "`nUnattached DSK:`t<no orphaned resources detected>"}
If(!$overallOrphanedNIC){ $overallOrphanedNIC = "`nUnattached NIC:`t<no orphaned resources detected>"}
If(!$overallOrphanedNSG){ $overallOrphanedNSG = "`nUnattached NSG:`t<no orphaned resources detected>"}
If(!$overallOrphanedPIP){ $overallOrphanedPIP = "`nUnattached PIP:`t<no orphaned resources detected>"}

Write-Output "`n****************** ORPHANED RESOURCES ******************`n`nDISKS/STORAGE$overallOrphanedDisks`n`nNETWORK INTERFACES$overallOrphanedNIC`n`nNETWORK SECURITY GROUPS$overallOrphanedNSG`n`nPUBLIC IP ADDRESSES$overallOrphanedPIP"  

If(!$overallEmptyResourceGroupsList){ $overallEmptyResourceGroupsList = "`n<no empty resource groups detected>"}
Write-Output "`n****************** EMPTY RESOURCE GROUPS ******************`n$overallEmptyResourceGroupsList"  

$totalInformation = ""
$totalInformation = "$summaryOverview`n`n****************** ORPHANED RESOURCES ******************`n$overallOrphanedDisks $overallOrphanedNIC $overallOrphanedNSG $overallOrphanedPIP`n`n****************** EMPTY RESOURCE GROUPS ******************`n$overallEmptyResourceGroupsList"
$resourcesDate = get-date -format yyyy-MM-dd_
$resourcesTimestamp = get-date -UFormat "%H.%M.%S.%Z"
$resourcesFinalStamp = $resourcesDate+$resourcesTimestamp
$totalInformation > "All_Orphaned_Resources_EmptyRGs_$resourcesFinalStamp.txt"
Write-Output "`n`n=> Exported All_Orphaned_Resources_EmptyRGs_$resourcesFinalStamp.txt`n"