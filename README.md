# Emulation of Fabric-Attached Memory for The Machine

Experience the developer environment of tomorrow's hardware _today_.  The Machine from Hewlett Packard Enterprise offers a new paradigm in memory-centric computing.  While the prototype hardware announced in 2016 will not be generally available, you can experiment with Fabric-Attached Memory (FAM) right now.

## Description

The Machine is a homogenous node-based cluster of SoCs running Linux with standard direct-attached DRAM.  All nodes also provide a range of memory attached to a foreign fabric (actually a Gen-Z precursor).   All segments of FAM are connected together and all of FAM is visible to all nodes in a shared fashion.  These statements should make much more sense after [reading the background material on the wiki.](https://github.com/FabricAttachedMemory/Emulation/wiki)

The shared global address space is manipulated from each node via the Linux filesystem API.  A new file system, the Librarian Filesystem Suite (LFS), allows familiar operations (open/create/allocate/delete) to request chunks of FAM.  Finally, the file can be memory-mapped via mmap(2) and deliver load-store operations directly to FAM without the OS or another API.  This is the promise of Memory-Driven Computing.  A daemon on each node communicates with a single server process to realize a global, distributed file system across nodes of The Machine.

Fabric-Attached Memory Emulation (FAME) is an environment that can be used to explore this new paradigm of The Machine.  FAME employs QEMU virtual machines (VMs) to be the "nodes" in The Machine.  A feature of QEMU, Inter-Virtual Machine Shared Memory (IVSHMEM), is configured across all the node VMs so they see a shared, global memory space.  This emulation is a "good-enough" approximation of real hardware to accomodate large amounts of software development on the nodes.  [Read more about emulation here](https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-and-Simulation) and [QEMU/FAME here](https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-via-Virtual-Machines).

## Pre-configuration for the script

The primary script in this repo is ``emulation_configure.bash``.   It will
create the necessary virtual network, VM bootable images, and control scripts.
Of course there's a little [work that needs to be done first](README2nd/Preconfigure.md).

## Running the script

After setting the appropriate environment variables, run the script; it takes
the desired number of VMs as its sole argument.  

    $ ./emulation_configure.bash n
    
Early on you'll be prompted for your password for "sudo" as several of
the commands in the script need root privilege.  If you want to run the 
script via sudo, you can do that, if you preserve the environment variables:

    $ sudo -E ./emulation_configure.bash n

### Behind the scenes

Some of the artifact names are based off the __$FAME_HOSTBASE__ variable.  For
example, if you use the default "node", all the files in __$FAME_DIR__ will
start with "node_" and the virtual network will be named "br_node".  In
the following discussion, BASE stands for the current value.

emulation_configure.bash performs the following actions:

1. Validates the host environment, ensuring commands are installed, verifying file space and internal consistency.
1. Creates a virtual intranet called "br_node" (br is short for "bridge") which
    * Uses NAT to bridge the intranet to the host system's external network.
    * Links all emulated VM "nodes" together on that intranet
    * Provides DHCP services via dnsmasq and DNS resolution for names like "BASE02"
1. Uses vmdebootstrap(1m) to create a new disk image (file) that serves as
the "golden image" for subsequent use.  This is the step that pulls from
__$FAME_MIRROR__ possibly using __$FAME_PROXY__. This template file is a
raw disk QEMU image name BASE_image.raw.  The default size of 6G
(__$FAME_VFS_GBYTES__)
will leave about 4.5 G of empty space, more than enough for a non-graphical
Linux development system.  If your host system is limited on disk space,
try reducing __$FAME_VFS_GBYTES__ and recreating the images.
1. Augments the *apt* environment on the golden image to also use __$FAME_L4FAME__, then installs the FAME packages (such as the LFS daemon).
1. Copy the template image for each VM and customize it (hostname, /etc/hosts,
etc etc etc).  The raw image is then converted to a qcow2 (copy-on-write) which shrinks its size down to 800 megabytes.  That will grow with use, limited by __$FAME_VFS_GBYTES__.  Each node gets its own image, BASE01.qcow2, BASE02.qcow2, etc.
1. Emits libvirt XML node definition files and and a script to load/start/stop/unload them from libvirt/virt-manager.  The XML files contain stanzas necessary to create the IVSHMEM connectivity to __$FAME_FAM__.

### Artifacts

The following files will be created in __$FAME_DIR__ after a successful run.

| Artifact | Description |
|----------|-------------|
| BASEXX.qcow2 | The disk image file for VM "node" XX |
| BASEXX.xml | The "domain" defintion file for "node" XX, loaded into virt-manager via "virsh define nodeXX.xml" |
| BASE_dpkg.list | All Debian packages included in each node. |
| BASE_env.sh | A shell script snippet containing the FAME_XXX values from the last run of emulation_configure.bash. |
| BASE_fame.in | The Librarian configuration file (read below) |
| BASE_log | Trace file of all steps by emulation_configure.bash |
| BASE_log.vm | Output from vmdebootstrap |
| BASE_network.xml | libvirt definition file for the assigned virtual network |
| BASE_template.img | Undifferentiated file-system golden image from vmdebootstrap. |
| BASE_virsh.sh | Shell script to to "define", "start", "stop", "destroy", and "undefine" all VM "nodes" |

## The Librarian File System (LFS)

The nodes (VMs) participate in a distributed file system.  That file system
is coordinated by a single master daemon known as the Librarian which runs
on a host (other than a VM).  In the FAME setup, the Librarian can run on the
QEMU host.  Before starting the nodes, the Librarian must be [configured as
discussed in this document.](README2nd/Librarian.md).

## Starting the nodes

Once the librarian is running, you can declare the nodes to the libvirt subsystem:

    cd $FAME_DIR
    ./node_virsh define
    ./node_virsh start

After "define", libvirt knows about the nodes so you could also run individual "virsh" commands to start nodes, or run virt-manager.

The root password for all nodes is "iforgot".  A normal user (__$FAME_USER__) also with password "iforgot", exists and is enabled as a full "sudo" account.  The normal user is configured with a phraseless ssh keypair expressed in templates/id_rsa.nophrase (the private key).  You can grab this file and use it in your personal .ssh/config setup.

Networking should be active on eth0.  /etc/hosts is set up for node01 through nodeXX.  The QEMU host system is known on each node by its own hostname and the name "torms"; see the section on the Librarian.  sshd is set up on every node for inter-node access as well as access from the host.

A reasonable development environment (gcc, make) is available at first boot.  "apt" and "aptitude" are configured to allow package installation and updates per the __$FAME_MIRROR__, __$FAME_L4FAME__, and __$FAME_PROXY__ settings above.

## Networking and DNS to the FAME "nodes"

Each node gets its IP address via DHCP
to the corresponding dnsmasq of the virtual intranet.  __$FAME_OCTETS123__
define the first three octets of the RFC1914 address, the default is 192.168.42.  N

For now, 

* BASE01 == 3OCTETS.1 (ie, node01 == 192.168.42.1)
* BASE02 == 3OCTETS.2 (ie, node02 == 192.168.42.2)
* etc.

There are several ways to resolve hostnames from the host (such as "node01"):

1. (Simplest) Manually edit the hosts "/etc/hosts" file
1. For a small number of nodes, add the Host/Hostname to $HOME/.ssh/config.
A change is needed anyway to utilize id_rsa.nophrase.
1. With resolvconf, NetworkManager, and systemd-resolved all vying for attention, true DNS-based resolution is left as an exercise to the reader.

You can ssh to the node as the normal __$FAME_USER__.  If you set your $HOME/.ssh/config file correctly using the id_rsa.nophrase private key the ssh occurs without further confirmation.

## Running FAME on non-Debian Linux host systems

[Read this document](README2nd/Docker.md) to execute emulation_configure.bash in a Docker container.  The resulting VMs and other files will still be left in __$FAME_DIR__ as expected, but now you can run them on a distro like RedHat or SLES.

## Running FAME on non-Linux host systems: Nested VMs

1. Install a hypervisor that will support recent Debian/Ubuntu distros
   * For Windows, use VMware Workstation.  [More details are given here](README2nd/Windows.md).
   * For Mac OSX, use Oracle VirtualBox.
1. Create a Debian/Ubuntu VM under the hypervisor as the "FAME host"
1. Enter the FAME host, git clone the Emulation repo and follow the above instructions

