# vSphereMgmt
Some useful PowerShell scripts for managing vSphere

## moveVM_batch_from55to65.ps1
This script is designed to move the VMs from one vCenter to another vCenter in batch, which the vSphere may or may not differ. 

### Scenario
In my real scenario, we needed to move a bunch of VMs from vSphere 5.5 to vSphere 6.5. There are 2 vSphere datacenter managed by different vCenter:
1. vCenter 5.5, manages dozens of vSphere 5.5 hosts without vSphere cluster, which all of them are using local datastores.
2. vCenter 6.5, manages a dozen of vSphere 6.5 hosts in a cluster, which built on top of shared storage with DRS storage cluster.

### Prerequisities
To use this script, there are several prerequisities:
1. Must have a shared datastore both mount on vSphere 5.5 and vSphere 6.5 with enough space.
2. Tt could be NFS datastore or iSCSI/FC SAN shared datastore, the script were only tested with NFS datastore, but other shared datastore could work.
3. 
