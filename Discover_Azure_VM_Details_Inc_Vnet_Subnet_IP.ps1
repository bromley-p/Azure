#*************************************************
# VIRTUAL MACHINE DETAILS INCLUDING VNET / SUBNET
#*************************************************

$azureVMResourcesAll = @()
$azureVMdetails = ""

# You can either have it check ALL subscriptions, or use a Where-Object to select particular subscriptions...
# NOTE: Best to use the Subscription ID, not the name (in case things get renamed!)

$subscriptions = Get-AzSubscription | Where-Object { $_.Id -eq "<YOUR_SUBSCRIPTION_ID>" }
#$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like "ITS-PROD*" -OR $_.Name -like "Information Technology Services"}
#$subscriptions = Get-AzSubscription

ForEach ($individualSubscription in $subscriptions) {

    Set-AzContext -Subscription $individualSubscription.id | Out-Null
    $azureVMdetails = Get-AzVM | ForEach-Object {
        
        $subscriptionName = ""
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
           'Subscription' = $individualSubscription.name
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
$azureVMResourcesAll | Export-csv AllvmDetails_$azureVMResourcesFinalStamp.csv -Append -NoTypeInformation
$azureVMResourcesAll  |  select-object 'Subscription','ResourceGroup','VNET','VM Name','VM Family','CPU (Cores)','Memory (GB)','PrivateIP','PublicIP' -First 10 | ft -AutoSize

Write-Output "`n=> Exported All_VM_Details_$azureVMResourcesFinalStamp.csv`n" 