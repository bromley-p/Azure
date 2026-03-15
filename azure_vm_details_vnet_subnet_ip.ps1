#*************************************************
# VIRTUAL MACHINE DETAILS INCLUDING VNET / SUBNET
#*************************************************

$azureVMResourcesAll = @()
$azureVMdetails = ""

# You can either have it check ALL subscriptions, or use a Where-Object to select particular subscriptions...
$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like "SubscriptionName1*" -OR $_.Name -like "SubscriptionName2*"} 
#$subscriptions = Get-AzSubscription
ForEach ($individualSubscription in $subscriptions) {
Set-AzContext -Subscription $individualSubscription.id

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

     $vm = $_
     $vmSize = $vm.HardwareProfile.VmSize
     $vmSizeDetails = Get-AzVMSize -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name | where-object {$_.name -eq $vmSize} | Select-Object Name,NumberofCores,MemoryinMB,OSDiskSizeInMB
     $vmOSType = $vm.StorageProfile.OsDisk.OsType

     $vmOSDiskSize = $vm.StorageProfile.OsDisk.DiskSizeGB
     If(!$vmOSDiskSize) { $vmOSDiskSize = "Size N/A (Deallocated VM)"}

     $vmDataDiskSize = $vm.StorageProfile.DataDisks.DiskSizeGB
     If(!$vmDataDiskSize) { $vmDataDiskSize = "Size N/A (Deallocated VM / No Data Disks)"}

     $nic = Get-AzNetworkInterface -ResourceGroupName $vm.ResourceGroupName -Name ($vm.NetworkProfile.NetworkInterfaces[0].Id.Split('/')[-1])
     $subnetId = $nic.IpConfigurations[0].Subnet.Id
     $vnetName = $subnetId.Split('/')[8]
     $resourceGroup = $vm.ResourceGroupName
     $subnet  = $subnetId.Split('/')[-1]

    $publicIp = '-'
     if ($nic.IpConfigurations[0].PublicIpAddress) {
         $pipId  = $nic.IpConfigurations[0].PublicIpAddress.Id
         $pipName = $pipId.Split('/')[-1]
         $pipRg  = $pipId.Split('/')[4]
         $publicIp = (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRg).IpAddress
     }

     [PSCustomObject]@{
        'Subscription' = $individualSubscription.name
        'Resource Group' = $resourceGroup
        'VNET Name'      = $vnetName
         SubnetName       = $subnet
        'PrivateIP' = $nic.IpConfigurations[0].PrivateIpAddress
        'Public IP address'  = $publicIp
        'Virtual Machine Name' = $vm.Name
	    'Operating System' = $vmOSType
	    'VM Size (Type)' = $vmSize
	    'Number of Cores' = $vmSizeDetails.NumberOfCores
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
