#*************************************************
# VIRTUAL MACHINE DETAILS INCLUDING VNET / SUBNET
#*************************************************

$azureVMResourcesAll = @()
$azureVMdetails = ""

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

    Set-AzContext -Subscription $subscriptionId | Out-Null
    $azureVMdetails = Get-AzVM | ForEach-Object {
        
        $vm = ""
        $vmSize = ""
        $vmSizeDetails = ""
        $vmOSType = ""
        $vmOSDiskSize = ""
        $vmDataDiskSize = ""
        $nic = ""
        $subnetId = ""
        $vnetName = ""
        $resourceGroup = ""
        $subnet = ""
    
        $publicIp = ""
        $pipId = ""
        $pipName = ""
        $pipRg = ""

        # Get VM related information
        $vm = $_
        $vmSize = $vm.HardwareProfile.VmSize
        $vmSizeDetails = Get-AzVMSize -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name | where-object {$_.name -eq $vmSize} | Select-Object Name,NumberofCores,MemoryinMB,OSDiskSizeInMB
        $vmOSType = $vm.StorageProfile.OsDisk.OsType

        # Get Disk Size related information
        $vmOSDiskSize = $vm.StorageProfile.OsDisk.DiskSizeGB
        If(!$vmOSDiskSize) { $vmOSDiskSize = "Size N/A (Deallocated VM)"}
        $vmDataDiskSize = $vm.StorageProfile.DataDisks.DiskSizeGB
        If(!$vmDataDiskSize) { $vmDataDiskSize = "Size N/A (Deallocated VM / No Data Disks)"}
        
        # Get Network related information
        $nic = Get-AzNetworkInterface -ResourceGroupName $vm.ResourceGroupName -Name ($vm.NetworkProfile.NetworkInterfaces[0].Id.Split('/')[-1])
        $subnetId = $nic.IpConfigurations[0].Subnet.Id
        $vnetName = $subnetId.Split('/')[8]
        $resourceGroup = $vm.ResourceGroupName
        $subnet  = $subnetId.Split('/')[-1]

        # Get IP related information
        $publicIp = '-'
        if ($nic.IpConfigurations[0].PublicIpAddress) {
            $pipId  = $nic.IpConfigurations[0].PublicIpAddress.Id
            $pipName = $pipId.Split('/')[-1]
            $pipRg  = $pipId.Split('/')[4]
            $publicIp = (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRg).IpAddress
        }

        # Gather all information to display
        [PSCustomObject]@{
           'Subscription' = $subscriptionName
           'ResourceGroup' = $resourceGroup
           'VNET'      = $vnetName
            SubnetName       = $subnet
           'PrivateIP' = $nic.IpConfigurations[0].PrivateIpAddress
           'PublicIP'  = $publicIp
           'VM Name' = $vm.Name
	       'Operating System' = $vmOSType
	       'VM Family' = $vmSize
	       'CPU (Cores)' = $vmSizeDetails.NumberOfCores
	       'Memory (GB)' = $vmSizeDetails.MemoryInMB/1024
	       'OS Drive (GB)' = $vmOSDiskSize
           'Data Drive (GB)' = $vmDataDiskSize       
        }
    }

    $azureVMResourcesAll += $azureVMdetails
}

$azureVMResourcesDate = get-date -format yyyy-MM-dd_
$azureVMResourcesTimestamp = get-date -UFormat "%H.%M.%S.%Z"
$azureVMResourcesSubscriptionNameTitle = $subscriptionName -replace " ","_"
$azureVMResourcesFinalStamp = $azureVMResourcesDate+$azureVMResourcesTimestamp
$azureVMResourcesAll | Export-csv "All_VM_Details_$azureVMResourcesFinalStamp.csv" -Append -NoTypeInformation
$azureVMResourcesAll  |  select-object 'Subscription','ResourceGroup','VNET','VM Name','VM Family','CPU (Cores)','Memory (GB)','PrivateIP','PublicIP' -First 10 | ft -AutoSize

Write-Output "`n=> Exported All_VM_Details_$azureVMResourcesFinalStamp.csv`n" 