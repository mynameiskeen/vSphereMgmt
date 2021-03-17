# vSphereMgmt
Some useful PowerShell scripts for managing vSphere

## 1. moveVM_batch_from55to65.ps1
This script is designed to move the VMs from one vCenter to another vCenter in batch, which the vSphere may or may not differ. 

### Scenario
In my real scenario, we needed to move a bunch of VMs from vSphere 5.5 to vSphere 6.5. There are 2 vSphere datacenter managed by different vCenter:
1. vCenter 5.5, manages dozens of vSphere 5.5 hosts without vSphere cluster, which all of them are using local datastores.
2. vCenter 6.5, manages a dozen of vSphere 6.5 hosts in a cluster, which built on top of shared storage with DRS storage cluster.

### Prerequisities
To use this script, there are several prerequisities:
1. Must have a shared datastore both mount on vSphere 5.5 and vSphere 6.5 with enough space.
2. It can be NFS datastore or iSCSI/FC SAN shared datastore, the script were only tested with NFS datastore, but other shared datastore could work.
3. The source vSphere can be clustered or independent, it doesn't matter theoretically.
4. The destination vSphere must be a vSphere cluster with DRS enabled, otherwise it will fail as the destination ResourcePool is using cluster.

### How to use
1. Install PowerShell V7.1.2 and PowerCLI V12, this script has only been tested in PowerShell V7.1.2 and PowerCLI V12 under CentOS 7
2. Create a .csv file with the VM which are ready to be moved, e.g.:

VMName|SrcNfsDS|IpAddr|DstNfsDs|DstPortGP|DstDS
--|:--:|:--:|:--:|:--:|:--:|
Test-VM|Datastore_NFS|192.168.1.1|Datastore_NFS|PortGroup-1|Shared_datastore

3. The csv columns:
   - VMName    :  The name of VM which to be moved.
   - SrcNfsDS  :  The NFS datastore in vSphere 5.5.
   - IpAddr    :  The ip address of the VM.
   - DstNfsDs  :  The destination NFS datastore.
   - DstPortGP :  The port group of the VM in vSphere 6.5.
   - DstDS     :  The datastore in vSphere 6.5 which the VM will be finally reside. 

4.  Command exapmles:

```powershell
abc
```
6.  1
7.  
