# Emulation of Fabric-Attached Memory for The Machine

Experience the developer environment of next year's hardware _today_.  The Machine from Hewlett Packard Enterprise offers a new paradigm in memory-centric computing.  While the prototype hardware announced in 2016 will not be generally available, you can experiment with Fabric-Attached Memory (FAM) right now.

## Description

The Machine is a homogenous node-based cluster of SoCs running Linux with standard direct-attached DRAM.  All nodes also provide a range of memory attached to a foreign fabric (actually a Gen-Z precursor).   All segments of FAM are connected together and all of FAM is visible to all nodes in a shared fashion.  These statements should make much more sense after [reading the background material on the wiki.](https://github.com/FabricAttachedMemory/Emulation/wiki)

The shared global address space is manipulated on each node via the Linux filesystem API.  A new file system, the Librarian Filesystem Suite (LFS), allows familiar operations (open/create/allocate/delete) to request chunks of FAM.  Finally, the file can be memory-mapped via mmap(2) and deliver load-store operations directly to FAM without the OS or another API.  This is the promise of Memory-Driven Computing.  A daemon on each node communicates with a single server process to realize a global, distributed file system across nodes of The Machine.

Fabric-Attached Memory Emulation (FAME) is an environment that can be used to explore this new paradigm of The Machine.  FAME employs QEMU virtual machines (VMs) to be the "nodes" in The Machine.  A feature of QEMU, Inter-Virtual Machine Shared Memory (IVSHMEM), is configured across all the node VMs so they see a shared, global memory space.  This emulation is a "good-enough" approximation of real hardware to allow large amounts of software development on the nodes.  [Read more about emulation here](https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-and-Simulation) and [QEMU/FAME here](https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-via-Virtual-Machines).

## Configuration for emulation_configure.bash

Prior experience with the QEMU/KVM suite and virsh command is useful but not absolutely required.

Before you can run the script some conditions need to be met.  Some of the are packages, some are environment variables, and some involve file locations.

### OS and extra packages

emulation_configure.bash must be run in a Debian environment.  Debian Stretch (9.2 and later) have been tested recently, as has Ubuntu 16 and 17.

Install packages for the commands __vmdebootstrap, sudo, and virsh__.  The actual package names may differ depending on your exact distro.

### Artifact directory and the FAME IVSHMEM backing file

The node emulated FAM is backed on the QEMU host by a file in the host file system.  Thus the emulated FAM is persistent (with respect to the lifetime of the IVSHMEM backing file).  This file must be created before running the configuration script.  Additionally, the script will generate files (node images, logs, etc).   All node VMs will share that one file so the global shared address space effect is realized.

First choose a location for all these files; a reasonable place is $HOME/FAME.  Export the following environment variable then create the directory:

```
    $ export FAME_DIR=$HOME/FAME
    $ mkdir $FAME_DIR
```

The backing store file must exist before running the script as it is scanned for size during VM configuration.  The file must be "big enough" to hold the expected data from all nodes (VMs).  The size must be between 1G and 256G and must be a power of 2.  There can be a little trial and error to get it right for your usage, but changing it and re-running the script is trivial.  The file is referenced by the $FAME_FAM variable.  A good location is in $FAME_DIR (but that's not a requirement).
There are a few other attributes that should be set now:

```
    $ export FAME_FAM=$FAME_DIR/FAM   # So the file is at $HOME/FAME/FAM
    $ fallocate -l 16G $FAME_FAM
    $ chgrp libvirt-qemu $FAME_FAM
    $ chmod 660 $FAME_FAM
```

### Environment variables

Two have already been discussed (FAME_DIR and FAME_FAM), here are the rest.  

First, http_proxy and https_proxy will be take from existing variables and used as defaults.

Second, understand that node VM images are build from two repos:

1. A "stock" Debian repo that feeds vmdebootstrap for the bulk of the VM image
1. An "L4FAME" (Linux for FAME) repo that has about a dozen packages needed by each node.

Environment variables specify the repo locations as well as other QEMU operating values.  They are listed here in alphabetical order:

| Variable | Purpose | Default |
|----------|---------|---------|
| FAME_DIR | All resulting artifacts are located here, including "env.sh" that lists the FAME_XXX values.  This is a good place to allocate $FAME_FAM. | Must be explicitly set |
| FAME_FAM | The "backing store" for the Global NVM seen by the nodes; it's the file used by QEMU IVSHMEM. | Must be explicitly set |
| FAME_KERNEL | The kernel package pulled from the $FAME_L4FAME repo. | linux-image-4.14.0 |
| FAME_L4FAME | The auxiliary L4FAME repo.  The default global copy is maintained by HPE but there are ways to build your own. | http://downloads.linux.hpe.com/repo/l4fame/Debian |
| FAME_MIRROR | The primary Debian repo used by vmdebootstrap. | http://ftp.us.debian.org/debian |
| FAME_PROXY | Any proxy needed to reach $FAME_MIRROR.  It can be different from $http_proxy if you have a weird setup. | $http_proxy |
| FAME_USER | The normal (non-root) user on each node | l4mdc |
| FAME_VCPUS | The number of virtual CPUs for each VM | 2 |
| FAME_VDRAM | Virtual DRAM allocated for each VM in KiB | 768432 |
| FAME_VFS_GBYTES | The maximum size of the golden image and each node VM image | 6 |
| FAME_VERBOSE | Normally the script only emits cursory summary messages.  If VERBOSE set to any value (like "yes"), step-by-step operations are sent to stdout and the file $FAME_DIR/fabric_emulation.log | unset |

If you run the script with no options it will print the current variable values:

```
$ ./emulation_configure.bash
http_proxy=
https_proxy=
FAME_DIR=
FAME_FAM=
FAME_KERNEL=linux-image-4.14.0-fame
FAME_L4FAME=http://downloads.linux.hpe.com/repo/l4fame/Debian
FAME_MIRROR=http://ftp.us.debian.org/debian
FAME_PROXY=
FAME_USER=l4mdc
FAME_VCPUS=2
FAME_VDRAM=786432
FAME_VERBOSE=
FAME_VFS_GBYTES=6
```

Variables can be set and exported for use prior to running the script.  When it is run with an argument to create VMs, the values will be stored in $FAME_DIR/env.sh.  This file can be sourced to recreate the desired runtime.

After setting variables, run the script; it takes the desired number of VMs as its sole argument.  

    $ ./emulation_configure.bash n
    
Early on you'll be prompted early for your password for "sudo", as several of the commands in the script need root privilege.  If you want to run the script via sudo, you can do that, if you preserve the environment variables:

    $ sudo -E ./emulation_configure.bash n

## Behind the scenes

emulation_configure.bash performs the following actions:

1. Validates the host environment, ensuring commands are installed, verifying file space and internal consistency.
1. Creates a libvirt virtual bridged network called "node_emul" which
    1. Provides DHCP services via dnsmasq, and DNS resolution for names like "node02"
    1. Links all emulated VM "nodes" together on an intranet (ala The Machine)
    1. Uses NAT to connect the intranet to the host system's external network.
1. Uses vmdebootstrap(1m) to create a new disk image (file) that serves
   as the "golden image" for subsequent use.  This is the step that pulls
   from $FAME_MIRROR possibly using $FAME_PROXY.  Most of the configuration
   is specified in the templates/vmd_X.  The specific file is dependent on
   the version of vmdebootstrap on the host system.  This template file is a
   raw disk image yielding about eight gigabytes of file system space for
   a VM, more than enough for a non-graphical Linux development system.
1. Copy the template image for each VM and customize it (hostname,
   /etc/hosts, /etc/resolv.conf, root and user "l4mdc").  The raw image is
   then converted to a qcow2 (copy-on-write) which shrinks its size down to
   800 megabytes.  That will grow with use.  The qcow2 files are created in
   $FAME_DIR.
1. Emits libvirt XML node definition files and and a script to 
   load/start/stop/unload them from libvirt/virt-manager.  Those files are
   all written to $FAME_DIR.  The XML files contain stanzas necessary to
   create the IVSHMEM connectivity (see below).

## Artifacts

The following files will be created in $FAME_DIR after a successful run.  Note: FAME_DIR was originally TMPDIR, but that variable is suppressed by glibc on setuid programs which breaks under certain uses of sudo.

| Artifact | Description |
|----------|-------------|
| env.sh | A shell script snippet containing the FAME_XXX values from the last run of emulation_configure.bash. |
| nodeXX.qcow2 | The disk image file for VM "node" XX |
| nodeXX.xml | The "domain" defintion file for "node" XX, loaded into virt-manager via "virsh define nodeXX.xml" |
| emulation_configure.log | Trace file of all steps by emulation_configure.bash |
| node_template.img |	Pristine (un-customized) file-system golden image of vmdebootstrap. |
| node_virsh.sh | Shell script to to "define", "start", "stop", "destroy", and "undefine" all VM "nodes" |

## The Librarian File System (LFS)

The nodes (VMs) participate in a distributed file system.  That file system
is coordinated by a single master daemon known as the Librarian.  Before
starting the nodes, the Librarian must be 
**[configured as discussed in this document.](Librarian.md)**  Values used
in this configuration step have a direct impact on the size of $FAME_FAM.

## Starting the nodes

Once the librarian is running, you can declare the nodes to the libvirt subsystem:

1. cd $FAME_DIR
1. ./node_virsh define
1. ./node_virsh start

After "define", libvirt knows about the nodes so you could also run 
individual "virsh" commands to start nodes, or run virt-manager.

The root password for all nodes is "iforgot".  A normal user also
exists, "l4mdc", also with password "iforgot", and is enabled as a full
"sudo" account.  The l4mdc user is configured with a phraseless ssh
keypair expressed in id_rsa.nophrase (the private key).

Networking should be active on eth0.  /etc/hosts is set up for "nodes" node01
through nodeXX.  The QEMU host system is known by its own hostname and 
the name "torms"; see the section on the Librarian.  sshd is set up on
every node for inter-node access as well as access from the host.

A reasonable development environment (gcc, make) is available at first boot.
"apt" and "aptitude" are configured to allow package installation and
updates per the FAME_MIRROR, FAME_L4FAME, and FAME_PROXY settings above.

## Networking and DNS to the FAME "nodes"

With resolvconf, NetworkManager, and systemd-resolved all vying for attention,
this is highly non-deterministic :-)   More will be revealed...

For now, node01 == 192.168.42.1, node02 == 192.168.42.2, etc.

You can ssh to the node as the "l4tm" user.  If you set your $HOME/.ssh/config
file correctly using the id_rsa.nophrase private key the ssh occurs without
further typing.

## Running FAME on non-Debian host systems

[Read this document](Docker.md) to execute emulation_configure.bash in a Docker
container.  The resulting VMs and other files will still be left in $FAME_DIR
as expected, but now you can run on a distro like RedHat or SLES.
