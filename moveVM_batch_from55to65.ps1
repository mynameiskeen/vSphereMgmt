#!/opt/microsoft/powershell/7/pwsh

<#
.SYNOPSIS
    This script is used to move multiple VMs from a 5.5 vSphere to a 6.5 vSphere Cluster
    by using a shared NFS datastore mounted both on vSphere 5.5 and vSphere 6.5
.DESCRIPTION
    The steps of the migration:
      1. Power off the VM and move it to the shared NFS datastore
      2. Register the VM in vSphere 6.5 cluster
      3. Modify the network adapter to the right port group
      4. Power on the VM and check the network connectivity
      5. Move the VM from NFS datastore to the final datastore with live vMotion
.NOTES
    File Name      : moveVM_batch_from55to65.ps1
    Author         : Keen Wang
    Prerequisite   : Tested in PowerShell V7.1.2 under CentOS 7
    Copyright      : 2021 - Keen Wang/iBOXCHAIN INFORMATION TECHNOLOGY CO.,LTD
    Version        : 2021-03-14     V0.1, the very first version
                     
.PARAMETER path
    Specifies the path of a csv file contains all the VMs need to be moved
.EXAMPLE
    Example for csv contents
        VMName    :  The name of VM which to be moved.
        SrcNfsDS  :  The NFS datastore in vSphere 5.5.
        IpAddr    :  The ip address of the VM.
        DstNfsDs  :  The destination NFS datastore.
        DstPortGP :  The port group of the VM in vSphere 6.5.
        DstDS     :  The datastore in vSphere 6.5 which the VM will be finally reside.
    Example:
        ./createVM_batch.ps1 -Path vm_list.csv
        And then input the VCSA password

        or 
        ./createVM_batch.ps1 -Path vm_list.csv -PassFile password.txt
#>

###############################################################################
## Define input parameters
## -Path, the CSV file path contains VM to be moved
## -PassFile, the file contains the password generated by 
##      "ConvertTo-SecureString -String $password -AsPlainText -Force | `
##       ConvertFrom-SecureString"
###############################################################################

param
(
    [Parameter(Mandatory=$True)]
    [string]$Path,
    [Parameter()]
    [string]$PassFile
)

# Define vCenter host
$VC55Host = ""
$VC65Host = ""

# Debug log switch
# $DebugPreference = "Continue"

###############################################################################
## Define functions to write output
## Writes normal message with GREEN
## Writes error message with RED
###############################################################################
function Write-Info ($msg){
    Write-Host -ForegroundColor 10 "$(get-date -format 'yyyy-MM-dd HH:mm:ss'): $msg"
}
function Write-Warning ($msg){
    Write-Host -ForegroundColor Yellow "$(get-date -format 'yyyy-MM-dd HH:mm:ss'): $msg"
}
function Write-Debugg ($msg){
    Write-Debug "$(get-date -format 'yyyy-MM-dd HH:mm:ss'): $msg"
}

function Write-Err ($msg){
    Write-Error "$(get-date -format 'yyyy-MM-dd HH:mm:ss'): $msg" -ErrorAction Stop
}

###############################################################################
## Process password
###############################################################################

# If $PassFile was set, read the password from $PassFile
if ( ($PassFile) -and (Test-Path $PassFile) ){
    $securePass = Get-Content $PassFile | ConvertTo-SecureString
    $password =  ConvertFrom-SecureString -SecureString $securePass -AsPlainText
} elseif ( ($PassFile) -and -not (Test-Path $PassFile) ) {
    Write-Err "The path: $PassFile does not exist"
} else {
    $securePass = Read-Host -Prompt 'Input vcsa password' -AsSecureString
    $password =  ConvertFrom-SecureString -SecureString $securePass -AsPlainText
}

###############################################################################
## Import csv file
###############################################################################

##Test if the $path exists
if (Test-Path $Path) {
    ##Import the VM list from CSV file
    Write-Info "==================== Importing the VM List from: $Path ."
    $Content = Import-Csv $Path
    } else {
    Write-Err  "The path: $Path does not exist."
}

###############################################################################
## Define functions 
###############################################################################
function Confirm-VMStatus ($VMName, $VIServer) {
    <#
    .SYNOPSIS
    Check the status of the VM
    .DESCRIPTION
    The VM ready to be moved should be powered off first
    .PARAMETER VMName
    The name of the VM which need to be moved
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>
    
    # Check if VM exists
    Write-Debugg "Command - `$vm = Get-VM -Name $VMName -Server $VIServer -EA SilentlyContinue"
    $vm = Get-VM -Name $VMName -Server $VIServer -EA SilentlyContinue
    if ($? -eq $false) {
        throw "VM $VMName does not exist or failed to get"
    }
    Write-Debugg "Variable - `$vm: $vm"
    # Check the VM status, if it's powered on,  raise an error
    if ($vm.PowerState -eq "PoweredOn") {
        throw "VM $VMName is still running, please power off first"
    }

}

##########Confirm-NFSStatus
function Confirm-NFSStatus ($VM, $NfsDSName, $VIServer) {
    <#
    .SYNOPSIS
    Check if a NFS datastore exists, and if the free space is enough to hold
    the vm migration.
    .DESCRIPTION
    First, check if the NFS datastore exists
    Second, get the size of the VM, compare with the free space of the NFS
    datastore, to see if there's enough space to perform the migration.
    .PARAMETER VM
    The VM instance object, generated by Get-VM
    .PARAMETER NfsDSName
    The name of the NFS datastore in vSphere 5.5
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>

    # Check if NFS datastore exists
    Write-Debugg "Command - `$nfsDS = Get-Datastore -Name $NfsDSName -Server $VIServer -EA SilentlyContinue"
    $nfsDS = Get-Datastore -Name $NfsDSName -Server $VIServer -EA SilentlyContinue
    if ($? -eq $false) {
        throw "NFS datastore: $NfsDSName does not exist or failed to get"
    }
    Write-Debugg "Variable - `$nfsDS: $nfsDS"

    # Check if NFS datastore can be accessed from the VMHost of the VM 
    $VMHost = Get-VMHost -VM $VM -Server $VIServer
    Write-Debugg "Variable - `$VMHost: $VMHost"
    Write-Debugg "Command - Get-Datastore -Name $NfsDSName -VMHost $VMHost -Server $VIServer -EA SilentlyContinue"
    Get-Datastore -Name $NfsDSName -VMHost $VMHost -Server $VIServer -EA SilentlyContinue | Out-Null
    if ($? -eq $false) {
        throw "NFS datastore: $NfsDSName was not found on VMHost: $VMHost"
    }

    # Get the size of the VM disk
    $vmUsedSpace = [math]::Round($VM.UsedSpaceGB,2)
    Write-Debugg "Variable - `$vmUsedSpace: $vmUsedSpace"

    # Get the free space of the NFS datastore
    $dsFreeSpace = [math]::Round($nfsDS.FreeSpaceGB,2)
    Write-Debugg "Variable - `$dsFreeSpace: $dsFreeSpace"

    # Compare the free space of NFS datastore with the size of the VM disk
    if ( $dsFreeSpace -lt $vmUsedSpace ) {
        throw "NFS datastore: $NfsDSName does not have enough free space to hold VM: $VM.Name"
    }
}

##########Move-ToNfs
function Move-ToNfs ($VMName, $NfsDSName, $VIServer) {
    <#
    .SYNOPSIS
    Move the VM to NFS datastore
    .DESCRIPTION
    Migrate the storage of the VM from local datastore to NFS datastore using async
    mode, which means the migration will be running in the back ground.
    This function should return the task id of the async task
    .PARAMETER VMName
    The name of the VM which need to be moved
    .PARAMETER NfsDSName
    The name of the NFS datastore in vSphere 5.5
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection   
    #>

    # Get VMHost for VM
    Write-Debugg "Command - `$srcVMHost = Get-VMHost -VM $VMName -Server $VIServer"
    $srcVMHost = Get-VMHost -VM $VMName -Server $VIServer
    Write-Debugg "Variable - `$srcVMHost: $srcVMHost"

    # Get the NFS datastore
    Write-Debugg "Command - `$srcNfsDs = Get-Datastore -VMHost $srcVMHost -Name $NfsDSName -Server $VIServer"
    $srcNfsDs = Get-Datastore -VMHost $srcVMHost -Name $NfsDSName -Server $VIServer
    Write-Debugg "Variable - `$srcNfsDs: $srcNfsDs"
    # Move the VM to NFS datastore
    try {

        Write-Debugg "Command - `$task = Move-VM -VM $VMName -Datastore $srcNfsDs -DiskStorageFormat Thin -Confirm:$false -RunAsync -Server $VIServer -EA SilentlyContinue"
        $task = Move-VM -VM $VMName -Datastore $srcNfsDs -DiskStorageFormat Thin -Confirm:$false -RunAsync -Server $VIServer -EA SilentlyContinue
        Write-Debugg "Variable - `$task: $task"
        # Get the task id
        $taskId = $task.Id
        Write-Debugg "Variable - `$taskId: $taskId"
    }
    catch [Exception]{
        $exception = $_.Exception
        throw "move VM: $VMName failed with error: $exception"
    }
    # Return the task id
    $taskId
}


##########Register-VM
function Register-VM ($VMName, $NfsDSName, $VIServer) {
    <#
    .SYNOPSIS
    Register the VM in vSphere 6.5
    .DESCRIPTION
    First find the vmx file path in the NFS datastore, then using New-VM to register 
    the VM in vSphere 6.5
    .PARAMETER VMName
    The name of the VM which need to be moved
    .PARAMETER NfsDSName
    he name of the NFS datastore in vSphere 6.5
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>

    # Get NFS datastore in vSphere 6.5
    Write-Debugg "Command - `$dstNfsDs = Get-Datastore -Name $NfsDSName -Server $VIServer"
    $dstNfsDs = Get-Datastore -Name $NfsDSName -Server $VIServer
    Write-Debugg "Variable - `$dstNfsDs: $dstNfsDs"

    # Get Cluster
    Write-Debugg "Command - `$dstCluster = Get-Cluster -Server $VIServer"
    $dstCluster = Get-Cluster -Server $VIServer
    Write-Debugg "Variable - `$dstCluster: $dstCluster"

    # Find VMX file
    # Assemble datastore path of VM
    $dsPathOfVM = "["+$dstNfsDs.Name+"]/"+$VMName
    Write-Debugg "Variable - `$dsPathOfVM: $dsPathOfVM"

    # Define a datastore view
    Write-Debugg "Command - `$dstNfsDsView = Get-View -Id $dstNfsDs.ExtensionData.Browser -Server $VIServer"
    $dstNfsDsView = Get-View -Id $dstNfsDs.ExtensionData.Browser -Server $VIServer
    Write-Debugg "Variable - `$dstNfsDsView: $dstNfsDsView"

    # Define a search specification for searching VMX file
    $searchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
    $searchSpec.matchpattern = $VMName+".vmx"
    Write-Debugg "Variable - `$searchSpec: $searchSpec"

    # Search the pattern in $dstNfsDsView using path of $dsPathOfVM
    Write-Debugg "Command - `$searchResult = $dstNfsDsView.SearchDatastoreSubFolders($dsPathOfVM, $searchSpec)"
    $searchResult = $dstNfsDsView.SearchDatastoreSubFolders($dsPathOfVM, $searchSpec)
    Write-Debugg "Variable - `$searchResult: $searchResult"

    if ($searchResult.FolderPath){

        $vmxFile = $searchResult.FolderPath + $searchResult.File.Path
        Write-Debugg "Variable - `$vmxFile: $vmxFile"
        # Register the VM
        try {
            Write-Debugg "Command - `$task = New-VM -VMFilePath $vmxFile -ResourcePool $dstCluster -Server $VIServer -RunAsync"
            # Using -RunAsync to eliminate the progress bar
            $task = New-VM -VMFilePath $vmxFile -ResourcePool $dstCluster -Server $VIServer -RunAsync
            Write-Debugg "Variable - `$task: $task"

            # Start a loop to check the status of New-VM
            for ($i=1; $i -le 30; $i++){

                # Check the state of the task
                $state = $task.State
                Write-Debugg "Variable - `$task: $state"
                if ($state -eq "Success") {
                    break
                } elseif ($state -eq "Error") {
                    throw "register VM: $VMName failed, please check the event of vCenter"
                }
                # Sleep for 2 seconds
                Start-Sleep -s 2

                # If the loop goes to 30 and the state is neither "Success" nor "Error"
                # Break the loop and raise error
                if ($i -eq 30) {
                    throw "register VM: $VMName take too long, please check the event of vCenter"
                }
            }
        }
        catch [Exception]{
            $exception = $_.Exception
            throw "register VM: $VMName failed with error: $exception"
        }
    } else {
        throw "can not find vmx file for VM: $VMName in NFS datastore: $NfsDSName"
    }
}

##########Set-VMConfig
function Set-VMConfig ($VM, $PGName, $VIServer) {
    <#
    .SYNOPSIS
    Config the VM port group and hardware version after registered
    .DESCRIPTION
    As the port groups of VDS in vSphere 5.5 and 6.5 are different, the port group
    must be set to the appropriate one before starting the VM.
    The hardware version in vSphere 5.5 is 8, it should be upgraded to 13 in vSphere
    6.5 for better performance.
    .PARAMETER VM
    The VM instance object, generated by Get-VM
    .PARAMETER PGName
    The port group name in vSphere 6.5
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>

    # Get port group
    Write-Debugg "Command - `$pg = Get-VDPortgroup -Name $PGName -Server $VIServer -EA SilentlyContinue"
    $pg = Get-VDPortgroup -Name $PGName -Server $VIServer -EA SilentlyContinue
    if ( $? -eq $false ) {
        throw "portgroup $PGName does not exist or failed to get"
    }
    Write-Debugg "Variable - `$pg: $pg"
    $networkAdapter = Get-NetworkAdapter $VM -Server $VIServer 
    Write-Debugg "Variable - `$networkAdapter: $networkAdapter"
    # Set the network of the VM to port group $PGName
    try {
        Write-Debugg "Command - Set-NetworkAdapter -NetworkAdapter $networkAdapter -Portgroup $pg -Server $VIServer -Confirm:$false -RunAsync"
        # Using -RunAsync to eliminate the progress bar and the space output to the terminal
        Set-NetworkAdapter -NetworkAdapter $networkAdapter -Portgroup $pg -Server $VIServer -Confirm:$false -RunAsync | Out-Null
        
        # Start a loop to check the status of Start-VM
        for ($i=1; $i -le 30; $i++){

            # Get task
            Write-Debugg "Command - `$task = Get-Task -Server $VIServer | `
            Where-Object { $_.Name -eq 'ReconfigVM_Task'  -and $_.ExtensionData.Info.EntityName -eq $VMName }"
            $task = Get-Task -Server $VIServer | 
                Where-Object { $_.Name -eq 'ReconfigVM_Task'  -and $_.ExtensionData.Info.EntityName -eq $VMName }
            Write-Debugg "Variable - `$task: $task"
            # Get task state, break the loop if it's "Success" 
            $state = $task.State
            if ($state -eq "Success") {
                break
            } elseif ($state -eq "Error") {
                throw "config VM: $VMName failed, please check the event of vCenter"
            }
            # Sleep for 2 seconds
            Start-Sleep -s 2   

            # If the loop goes to 30 and the state is neither "Success" nor "Error"
            # Break the loop and raise error
            if ($i -eq 30) {
                throw "config VM: $VMName take too long, please check the event of vCenter"
            }
        }
    }
    catch [Exception]{
        $exception = $_.Exception
        $VMName = $VM.Name
        throw "set network adapter for VM $VMName failed with error: $exception"    
    }
}

##########Move-VMDatastore
function Move-VMDatastore ($VM, $DSName, $VIServer) {
    <#
    .SYNOPSIS
    Move the VM from NFS datastore to final datastore in vSphere 6.5
    .DESCRIPTION
    This step is live migration using vMotion
    .PARAMETER VM
    The name of the VM which need to be moved
    .PARAMETER DSName
    The name of the datastore which the VM will be resided
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>

    # Get datastore
    Write-Debugg "Command - `$ds = Get-Datastore -Name $DSName -Server $VIServer -EA SilentlyContinue"
    $ds = Get-Datastore -Name $DSName -Server $VIServer -EA SilentlyContinue
    if ( $? -eq $false ) {
        throw "datastore $DSName does not exist or failed to get"
    }
    Write-Debugg "Variable - `$ds: $ds"

    # Move the VM
    try {
        Write-Debugg "Command - `$task = Move-VM -VM $VM -Datastore $ds -Server $VIServer -Confirm:$false -RunAsync"
        $task = Move-VM -VM $VM -Datastore $ds -Server $VIServer -Confirm:$false -RunAsync
        Write-Debugg "Variable - `$task: $task"
        # Get the task id
        $taskId = $task.Id
        Write-Debugg "Variable - `$taskId: $taskId"
    }
    catch [Exception]{
        $exception = $_.Exception
        throw "move vm from NFS datastore to $DSName failed with error: $exception"  
    }

    # Return the task id
    $taskId
}

##########Get-TaskProgress
function Get-TaskProgress($VMName, $Id, $VIServer) {
    <#
    .SYNOPSIS
    Check the progress of the async task
    .DESCRIPTION
    There are 2 steps of datastore migration, first from local datastore to NFS
    datastore in vSphere 5.5 and then from NFS datastore to local datastore in 
    vSphere 6.5. These 2 steps are both performed asynchronously. This function 
    is used to check the states and progress of async task.
    .PARAMETER VMName
    The name of the VM which need to be moved
    .PARAMETER Id
    The task Id of async task
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>

    # Set timeout loop
    $i = 0
    # Start a endless loop
    while ($true) {
        # Get tasks 
        Write-Debugg "Command - `$task = Get-Task -Server $VIServer| Where-Object { $_.Id -eq $Id }"
        $task = Get-Task -Server $VIServer| Where-Object { $_.Id -eq $Id }
        Write-Debugg "Variable - `$task: $task"

        # Get percent completed
        $percent = $task.PercentComplete
        Write-Debugg "Variable - `$percent: $percent"
        # Get task state
        $state = $task.State
        Write-Debugg "Variable - `$state: $state"

        if ( $state -eq "Running" ) {
            Write-Info "---------- Moving VM:$VMName $percent% Complete"
        } elseif ($state -eq "Success"){
            Write-Info "---------- Moving VM:$VMName 100% Complete"
            # Break the loop once 100% complete
            break
        } else {
            throw "Moving VM:$VMName encounter unexpected error, please check the event of vCenter"
            # Break the loop once encoutered error
            break
        }
        # Sleep 2 minutes
        Start-Sleep -s 120
        # $i self-increasing, if $i reachs 120(120 means 120*2=240 minutes, at least 4 hours) 
        # and migration is still in progress, then cancel the task
        $i++
        if ( $i -gt 120) {
            Write-Info "---------- Moving VM:$vmname takes too long, cancel it"
            try {
                Write-Debugg "Command - Stop-Task -Task $task -Server $VIServer -EA SilentlyContinue"
                Stop-Task -Task $task -Server $VIServer -EA SilentlyContinue
                break
            }
            catch [Exception]{
                $exception = $_.Exception
                $taskId = $task.Id
                throw "cancel task: $taskId failed with error: $exception"
                break
            }
        }
    }
}

##########Start-VM
function Start-VMachine($VMName, $IpAddr, $VIServer) {
    <#
    .SYNOPSIS
    Start the VM host and test the network connectivity
    .PARAMETER VMName
    The name of the VM which need to be moved
    .PARAMETER IpAddr
    The ip address of the VM
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>

    # Start VM
    try {
        Write-Debugg "Command - `$t = Start-VM -VM $VMName -Server $VIServer -RunAsync"
        # Using -RunAsync to eliminate the progress bar
        Start-VM -VM $VMName -Server $VIServer -RunAsync | Out-Null
        
        # Start a loop to check the status of Start-VM
        for ($i=1; $i -le 30; $i++){

            # Get task
            Write-Debugg "Command - `$task = Get-Task -Server $VIServer | `
            Where-Object { $_.Name -eq 'PowerOnVM_Task'  -and $_.ExtensionData.Info.EntityName -eq $VMName }"
            $task = Get-Task -Server $VIServer | 
                Where-Object { $_.Name -eq 'PowerOnVM_Task'  -and $_.ExtensionData.Info.EntityName -eq $VMName }
            Write-Debugg "Variable - `$task: $task"
            # Get task state, break the loop if it's "Success" 
            $state = $task.State
            if ($state -eq "Success") {
                break
            } elseif ($state -eq "Error") {
                throw "start VM: $VMName failed, please check the event of vCenter"
            }
            # Sleep for 2 seconds
            Start-Sleep -s 2   

            # If the loop goes to 30 and the state is neither "Success" nor "Error"
            # Break the loop and raise error
            if ($i -eq 30) {
                throw "start VM: $VMName take too long, please check the event of vCenter"
            }
        }
    }
    catch [Exception]{
        $exception = $_.Exception
        throw "start VM: $VMName failed with error: $exception"        
    }
    
    # Get VM
    Write-Debugg "Command - `$vm = Get-VM -Name $VMName -Server $VIServer"
    $vm = Get-VM -Name $VMName -Server $VIServer
    Write-Debugg "Variable - `$vm: $vm"

    $vmId = $VM.Id
    Write-Debugg "Variable - `$vmId: $vmId"
    # Get VMView
    Write-Debugg "Command - `$vmView = Get-View -Id $vmId"
    $vmView = Get-View -Id $vmId
    Write-Debugg "Variable - `$vmView: $vmView"

    Write-Debugg "Command - `$vmToolStatus = $vmView.Guest.ToolsVersionStatus"
    $vmToolStatus = $vmView.Guest.ToolsVersionStatus
    Write-Debugg "Variable - `$vmToolStatus: $vmToolStatus"

    # If no VMware Tools installed, sleep 60 seconds
    # else check the Guest OS state
    if ($vmToolStatus -eq "guestToolsNotInstalled"){
        Start-Sleep 60
    } else {
        # Get the VM Guest OS state, will not continue until state is "running"
        while ($true){

            $GuestOSState = $VM.ExtensionData.Guest.GuestState
            Write-Debugg "Variable - `$GuestOSState: $GuestOSState"

            # Break the loop if OS state is running
            if ($GuestOSState -eq 'running') {
                break
            }
            # Wait for 5 seconds
            Start-Sleep -s 5
        }
    }

    # Test network connectivity
    # Test-Connection will test 4 pings by default
    try {
        # Testing 3 times
        for ($i=1; $i -le 3; $i++) {

            Write-Debugg "Command - `$Tests = Test-Connection -TargetName $IpAddr -IPv4"
            $Tests = Test-Connection -TargetName $IpAddr -IPv4
            Write-Debugg "Variable - `$Tests: $Tests"

            $LastTest = $Tests | Select-Object -Last 1
            Write-Debugg "Variable - `$LastTest: $LastTest"

            $LastState = $LastTest.Status
            Write-Debugg "Variable - `$LastState: $LastState"

            # If last test is "Success", break the loop 
            if ($LastState -eq 'Success') {
                break
            # For the first 2 loop, wait for 5 seconds    
            } elseif ($i -le 2) {
                Start-Sleep -s 5
            } else {
                throw "failed after 3 retries"
            }
        }
    }
    catch [Exception]{
        $exception = $_.Exception
        throw "testing network connectivity of VM: $VMName with IP: $IpAddr failed with error: $exception"        
    }
}

##########Update-VM
function Update-VM($VMName, $VIServer) {
    <#
    .SYNOPSIS
    Check the if the version of VMware Tools is the lastest, if not then update
    .PARAMETER VMName
    The name of the VM which need to be moved
    .PARAMETER VIServer
    The vCenter Server connection object, generated by Connect-VIServer, using to 
    identify the appropriate vCenter connection
    #>
    
    # Get VM
    Write-Debugg "Command - `$vm = Get-VM -Name $VMName -Server $VIServer"
    $vm = Get-VM -Name $VMName -Server $VIServer
    Write-Debugg "Variable - `$vm: $vm"

    $vmId = $VM.Id
    Write-Debugg "Variable - `$vmId: $vmId"

    # Get VMView
    Write-Debugg "Command - `$vmView = Get-View -Id $vmId -Server $VIServer“
    $vmView = Get-View -Id $vmId -Server $VIServer
    Write-Debugg "Variable - `$vmView: $vmView"

    $vmToolStatus = $vmView.Guest.ToolsVersionStatus
    Write-Debugg "Variable - `$vmToolStatus: $vmToolStatus"

    # If the vmToolStatus is "guestToolsNeedUpgrade", then update the VM
    if ($vmToolStatus -eq "guestToolsNeedUpgrade"){
        try {
            Update-Tools -NoReboot -VM $vm -Server $VIServer | Out-Null
        }
        catch {
            $exception = $_.Exception
            throw "update VMtools for VM: $VMName failed with error: $exception"            
        }
    }  elseif ($vmToolStatus -eq "guestToolsNotInstalled"){
        Write-Warning "Please be noted, VM:$VMName has no VMware Tools installed"
    } 
}

###############################################################################
## Connects the vCenter 5.5 and vCenter 6.5
###############################################################################
Write-Info "==================== Connect to both vCenter 5.5 and 6.5 ===================="
Write-Info ""
Write-Info "========== [vCenter 5.5] Connecting to vCenter Server 172.16.50.249"
$VC55 = Connect-VIServer -Server $VC55Host -User root -Password $password -EA SilentlyContinue
if ($?) {
  Write-Info "========== [vCenter 5.5] vCenter 172.16.50.249 connected."
  } else {
  Write-Err "[vCenter 5.5] Failed to connect 172.16.50.249"
}

Write-Info "========== [vCenter 6.5] Connecting to vCenter Server 172.16.50.250"
$VC65 = Connect-VIServer -Server $VC65Host -User administrator@vsphere.local -Password $password -EA SilentlyContinue
if ($?) {
  Write-Info "========== [vCenter 6.5] vCenter 172.16.50.250 connected."
  } else {
  Write-Err "[vCenter 6.5] Failed to connect 172.16.50.250"
}
Write-Info ""
###############################################################################
## Start a foreach loop to check all resouces before migration started
###############################################################################
Write-Info "==================== Checking the status of VMs and datastores ===================="
foreach ( $line in $Content ) {

    ##Set the variables from csv
    $VMName    = $line.VMName
    $SrcNfsDS  = $line.SrcNfsDS
    $DstNfsDs  = $line.DstNfsDs
    $DstPortGP = $line.DstPortGP
    $DstDS     = $line.DstDS
    Write-Info ""
    Write-Info "========== Begin to pre-check all resources for VM: $VMName"
    # Check the VM status
    Write-Info "=====Step 1, [vCenter 5.5] Checking the status of VM: $VMName"
    try {
        Confirm-VMStatus -VMName $VMName -VIServer $VC55
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 1, [vCenter 5.5] Check VM: $VMName failed with error: $exception"
    }
    Write-Info "=====Step 1, [vCenter 5.5] VM: $VMName status checked"

    # Get VM
    $VM = Get-VM -Name $VMName -Server $VC55

    # Check the NFS datastore status in vCenter 5.5
    Write-Info "=====Step 2, [vCenter 5.5] Checking the status of NFS datastore: $SrcNfsDS"
    try {
        Confirm-NFSStatus -VM $VM -NfsDSName $SrcNfsDS -VIServer $VC55
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 2, [vCenter 5.5] Check NFS datastore: $SrcNfsDS failed with error: $exception"
    }
    Write-Info "=====Step 2, [vCenter 5.5] NFS datastore: $SrcNfsDS status checked"

    # Check the NFS datastore status in vCenter 6.5
    Write-Info "=====Step 3, [vCenter 6.5] Checking the status of NFS datastore: $DstNfsDs"
    try {
        Get-Datastore -Name $DstNfsDs -Server $VC65 -EA Stop | Out-Null
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 3, [vCenter 6.5] Check NFS datastore: $DstNfsDs failed with error: $exception"
    }
    Write-Info "=====Step 3, [vCenter 6.5] NFS datastore: $DstNfsDs status checked"

    # Check the final datastore status in vCenter 6.5
    Write-Info "=====Step 4, [vCenter 6.5] Checking the status of final datastore: $DstDS"
    try {
        Get-Datastore -Name $DstDS -Server $VC65 -EA Stop | Out-Null
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 4, [vCenter 6.5] Check datastore: $DstDS failed with error: $exception"
    }
    Write-Info "=====Step 4, [vCenter 6.5] Final datastore: $DstDS status checked"

    # Check the Portgroup in vCenter 6.5
    Write-Info "=====Step 5, [vCenter 6.5] Checking the status of port group: $DstPortGP"
    try {
        Get-VDPortgroup -Name $DstPortGP -Server $VC65 -EA Stop | Out-Null
    }
    catch {
        $exception = $_.Exception
        Write-Err "=====Step 5, [vCenter 6.5] Check port group: $DstPortGP $ failed with error: $exception"
    }
    Write-Info "=====Step 5, [vCenter 6.5] Port Group: $DstPortGP status checked"
    Write-Info "========== Pre-check for VM: $VMName done successfully"
}
Write-Info ""


###############################################################################
## Start a foreach loop to check all resouces before migration started
###############################################################################
Write-Info "==================== Moving the VMs from vSphere 5.5 to vSphere 6.5 ===================="
foreach ( $line in $Content ) {

    $taskId = ''
    ##Set the variables from csv
    $VMName    = $line.VMName
    $SrcNfsDS  = $line.SrcNfsDS
    $IpAddr    = $line.IpAddr
    $DstNfsDs  = $line.DstNfsDs
    $DstPortGP = $line.DstPortGP
    $DstDS     = $line.DstDS
    Write-Info ""
    Write-Info "========== Starting to move VM: $VMName"

    # Step 1, check the NFS datastore status in vCenter 5.5
    # The purpose of re-run this function is to check the free space of NFS datastore
    # make sure there's enough free space to perform the storage migration
    Write-Info "=====Step 1, [vCenter 5.5] Checking the free space of NFS datastore: $SrcNfsDS"
    try {
        Confirm-NFSStatus -VM $VM -NfsDSName $SrcNfsDS -VIServer $VC55
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 1, [vCenter 5.5] Check NFS datastore: $SrcNfsDS failed with error: $exception"
    }
    Write-Info "=====Step 1, [vCenter 5.5] NFS datastore: $SrcNfsDS free space checked"

    # Step 2, move VM to NFS datastore in vCenter 5.5
    Write-Info "=====Step 2, [vCenter 5.5] Moving VM $VMName to NFS datastore $SrcNfsDS"
    try {
        $taskId = Move-ToNfs -VMName $VMName -NfsDSName $SrcNfsDS -VIServer $VC55
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 2, [vCenter 5.5] Move VM $VMName to NFS datastore failed with error: $exception"
    }
    try {
        # Get task state
        Get-TaskProgress -VMName $VMName -Id $taskId -VIServer $VC55
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 2, [vCenter 5.5] Check task status failed with error: $exception"
    }
    Write-Info "=====Step 2, [vCenter 5.5] VM: $VMName has been moved to NFS datastore"

    # Step 3, register VM in vCenter 6.5
    Write-Info "=====Step 3, [vCenter 6.5] Registering VM: $VMName"
    try {
        Register-VM -VMName $VMName -NfsDSName $DstNfsDs -VIServer $VC65
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 3, [vCenter 6.5] Registering VM $VMName failed with error: $exception"
    }
    Write-Info "=====Step 3, [vCenter 6.5] VM: $VMName has been registered"

    # Step 4, config VM in vCenter 6.5
    Write-Info "=====Step 4, [vCenter 6.5] Configuring VM: $VMName with port group: $DstPortGP"
    # Get VM
    Write-Debugg "Command - `$VM = Get-VM -Name $VMName -Server $VC65"
    $VM = Get-VM -Name $VMName -Server $VC65
    try {
        Set-VMConfig -VM $VM -PGName $DstPortGP -VIServer $VC65
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 4, [vCenter 6.5] Configuring VM: $VMName failed with error: $exception"        
    }
    Write-Info "=====Step 4, [vCenter 6.5] VM: $VMName has been configured"

    # Step 5, start VM and testing the network connectivity
    Write-Info "=====Step 5, [vCenter 6.5] Starting VM: $VMName and testing network connectivity"
    try {
        Start-VMachine -VMName $VMName -IpAddr $IpAddr -VIServer $VC65
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 5, [vCenter 6.5] Starting VM $VMName failed with error: $exception"        
    }
    Write-Info "=====Step 5, [vCenter 6.5] VM: $VMName has been started and tested"
    
    # Step 6, move the VM from NFS datastore to final datastore
    Write-Info "=====Step 6, [vCenter 6.5] Moving VM: $VMName from NFS datastore to final datastore"
    try {
        $taskId = Move-VMDatastore -VM $VM -DSName $DstDS -VIServer $VC65
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 6, [vCenter 6.5] Moving VM: $VMName failed with error: $exception"
    }
    try {
        # Get task state
        Get-TaskProgress -VMName $VMName -Id $taskId -VIServer $VC65
    }
    catch [Exception]{
        $exception = $_.Exception
        Write-Err "=====Step 6, [vCenter 5.5] Check task status failed with error: $exception"
    }
    Write-Info "=====Step 6, [vCenter 6.5] VM: $VMName has been moved to final datastore: $DstDS"

    # Step 7, upgrade the VMTools to the lastest version
    Write-Info "=====Step 7, [vCenter 6.5] Updating VMTools for VM: $VMName"
    try {
        Update-VM -VMName $VMName -VIServer $VC65
    }
    catch [Exception]{
        Write-Err "=====Step 7, [vCenter 6.5] Updating VM: $VMName failed with error: $exception"
    }
    Write-Info "=====Step 7, [vCenter 6.5] VM: $VMName has been updated"

    # Print the finish log line
    Write-Info "========== VM: $VMName moved successfully"
}
Write-Info ""
Write-Info "==================== All VMs has been moved successfully ===================="