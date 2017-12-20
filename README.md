# Emulation of Fabric-Attached Memory for The Machine

Experience the developer environment of next year's hardware _today_.  The Machine from Hewlett Packard Enterprise prototype offers a new paradigm in memory-centric computing.  While the prototype hardware announced in 2016 will not be generally available, you can experiment with fabric-attached memory right now.

## Description

This repo delivers a script to create virtual machine file system images directly from a Debian repo.  VMs are then customized and configured to emulate the fabric-attached memory of The Machine.  Those statements should make much more sense after [reading the background material on the wiki.](https://github.com/FabricAttachedMemory/Emulation/wiki)

Fabric-Attached Memory Emulation is an environment that can be used to explore the new architectural paradigm of The Machine.  Some knowledge of The Machine architecture is useful to use this suite, but it actually ignores the minutiae of the hardware.  Reasonable comfort with the QEMU/KVM/libvirt/virsh suite is highly recommended.

The emulation employs QEMU virtual machines performing the role of "nodes" in The Machine.  Inter-Virtual Machine Shared Memory (IVSHMEM) is configured across all the "nodes" so they see a shared, global memory space.  This space can be accessed via mmap(2) and will behave just the same as the memory centric-computing on The Machine.

## Setup and Execution

The Machine project created a Debian derivative known as L4TM: Linux for
The Machine.  It follows that the emulation configurator script
*emulation_configure.bash* was created for Debian 8.x (Jessie).  
It has been upgraded to work with Stretch and Ubuntu 16/17.  The script
centers around the image produced by vmdebootstrap, and other packages
are required as well.  These existence of these packages is checked
by the script during its early phase.  You may get output requesting
the installation of additional packages to resolve.

If your host system is NOT Stretch or Ubuntu 16/17 you may be able to
use a Docker Stretch container to create the VMs, then run them on
your host OS.  That effort is just getting underway.

Before running *emulation_configure.sh* several environment variables must
be set or exported that represent choices for the script.  VM images are
build from two repos:

1. A "stock" Debian repo that gets Stretch via vmdebootstrap
2. An "L4FAME" (Linux for FAME) repo that has about a dozen packages
   needed by each node.

The environment variables specify the repo locations as well as QEMU
operating values.  They are listed here in alphabetical order:

| Variable | Purpose | Default |
|----------|---------|---------|
| FAME_FAM | The "backing store" for the Global NVM seen by the nodes; it's the file used by QEMU IVSHMEM. | REQUIRED! |
| FAME_KERNEL | The kernel package pulled from the $FAME_L4FAME repo (during
development multiple kernels existed). | linux-image-4.14.0-l4fame+ |
| FAME_L4FAME | The auxiliary L4FAME repo.  This global copy is maintained
by HPE but there are ways to build your own. | http://downloads.linux.hpe.com/repo/l4fame/Debian |
| FAME_MIRROR | The primary Debian repo used by vmdebootstrap. | http://ftp.us.debian.org/debian |
| FAME_OUTDIR | All resulting artifacts are located here, including "env.sh" that lists the FAME_XXX values.  $FAME_FAM is usually placed here. | /tmp |
| FAME_PROXY | Any proxy needed to reach $FAME_MIRROR. | $http_proxy |
| FAME_VCPUS | The number of virtual CPUs for each VM | 2 |
| FAME_VDRAM | Virtual DRAM allocated for each VM in KiB | 768432 |
| FAME_VERBOSE |Normally the script is fairly quiet, only emitting cursory progress messages.  If VERBOSE set to any value (like "yes"), step-by-step operations are sent to stdout and the file $FAME_OUTDIR/fabric_emulation.log | unset |

If you run the script with no options it will print the current values:

```
$ ./emulation_configure.bash
Environment:
http_proxy=http://some.proxy.net:8080
FAME_KERNEL=linux-image-4.14.0-l4fame+
FAME_L4FAME=http://downloads.linux.hpe.com/repo/l4fame/Debian
FAME_MIRROR=http://ftp.us.debian.org/debian
FAME_OUTDIR=/tmp
FAME_PROXY=
FAME_VCPUS=2
FAME_VDRAM=786432
FAME_VERBOSE=
```

Variables can be exported to be used by the script using:

    $ export FAME_MIRROR=http://a.b.com/debian
    $ export FAME_VERBOSE=yes

The file referenced by $FAME_FAM must exist and be over 1G.  It must also belong to the group "libvirt-qemu" and
have permissions 66x.  Suggestions:

    $ export FAME_OUTDIR=$HOME/FAME
    $ mkdir -p $FAME_OUTDIR
    $ export FAME_FAM=$FAME_OUTDIR/FAM
    $ fallocate -l 16G $FAME_FAM
    $ chgrp libvirt-qemu $FAME_FAM
    $ chmod 664 $FAME_FAM
    
The size of 16G will be explained below in the section on The Librarian.  Trust me, this is a good starting number.

After setting variables, run the script; it takes the desired number of VMs
as its sole argument.  Several of the commands in the script must be run
as root.  You can either run the script as "yourself" in which case you'll
be prompted early for your password:

    $ ./emulation_configure.bash n

or you can start it with sudo.  Variables must be seen in the script's
environment so use the "-E" command if invoking sudo directly:

    $ sudo -E ./emulation_configure.bash n

## Behind the scenes

emulation_configure.bash performs the following actions:

1. Validates the host environment, starting with execution as root or sudo.  While it doesn't explicitly limit its execution to Debian Jessie, it does check for commands that may not exist on other Debian variants.  Other things are checked like file space and internal consistency.
1. Creates a libvirt virtual bridged network called "node_emul" which
  2. Provides DHCP services via dnsmasq, and DNS resolution for names like "node02"
  2. Links all emulated VM "nodes" together on an intranet (ala The Machine)
  2. Uses NAT to connect the intranet to the host system's external network.
1. Uses vmdebootstrap(1m) to create a new disk image (file) that serves as the template for each VM's file system.  This is the step that pulls from the Debian mirror (see FAME_MIRROR and FAME_PROXY above).  Most of the configuration is specified in the templates/vmd_X.  The specific file is dependent on the version of vmdebootstrap on the host system.  This template file is a raw disk image yielding about eight gigabytes of file system space for a VM, more than enough for a non-graphical Linux development system.
1. Copy the template image for each VM and customize it (hostname, /etc/hosts, /etc/resolv.conf, root and user "l4tm").  The raw image is then converted to a qcow2 (copy-on-write) which shrinks its size down to 800 megabytes.  That will grow with use.  The qcow2 files are created in $FAME_OUTDIR.
1. Emits libvirt XML node definition files and scripts to load/start/stop/unload them from libvirt/virt-manager.  Those files are all in $FAME_OUTDIR.  The XML files contain stanzas necessary to create the IVSHMEM connectivity (see below).

## Artifacts

The following files will be created in $FAME_OUTDIR after a successful run.  Note: FAME_OUTDIR was originally TMPDIR, but that variable is suppressed by glibc on setuid programs which breaks under certain uses of sudo.

| Artifact | Description |
|----------|-------------|
| env.sh | A shell script snippet containing the FAME_XXX values from the last run of emulation_configure.bash. |
| nodeXX.qcow2 | The disk image file for VM "node" XX |
| nodeXX.xml | The "domain" defintion file for "node" XX, loaded into virt-manager via "virsh define nodeXX.xml" |
| node_emulation.log | Trace file of all steps by emulation_configure.bash |
| node_template.img |	Pristine (un-customized) file-system image of vmdebootstrap.  This is a partitioned disk image and is not needed to run the VMs. |
| node_virsh.sh | Shell script to to "define", "start", "destroy" (stop), and "undefine" all VM "nodes" |

## VM Guest Environment

The root password is "iforgot".  A single normal user also exists, "l4tm", with password "iforgot", and is enabled as a full "sudo" account.  The l4tm user is configured with a phraseless ssh keypair expressed in id_rsa.nophrase (the private key).

Networking should be active on eth0.  /etc/hosts is set up for "nodes" node01 through nodeXX.  The host system is known by its own hostname and the name "torms".   sshd is set up on every node for inter-node access as well as access from the host.

"apt" and "aptitude" are configured to allow package installation and updates per the FAME_MIRROR and FAME_PROXY settings above.

A reasonable development environment (gcc, make) is available.  This can be used to compile the simple "hello world" program found in the home directory of user "fabric".

## Networking and DNS to the "nodes"

With resolvconf, NetworkManager, and systemd-resolved all vying for attention, this is highly non-deterministic :-)   More will be revealed...

For now, node01 == 192.168.42.1, node-2 == 192.168.42.2, etc.

## IVSHMEM connectivity between all VMs

Memory-driven computing (MDC) in The Machine is done via memory accesses
identical to those used with legacy memory-mapping.  Emulation provides
a resource for such [user space programming via IVSHMEM]
(https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-via-Virtual-Machines).
Extra commands buried in the node_XX.xml file attach each VM "node" to the
same $FAME_FAM file.

Each VM sees a pseudo-PCI device with a memory base address register (BAR)
of size 1024 megabytes (one gigabyte).  It can be seen in detail via
"lspci -vv".  Resource2 is memory-mapped access to $FAME_FAM; its size is
the size of the file on the host sytstem.  This is presented to the VM kernel
as live, cacheable, unmapped physical address space.

The VM "physical" address space is backed on the host the file $FAME_FAM.
This file must exist before invoking emulation_configure.bash, and its size
must be a power of two.  Anything done to the address space on the VM is
reflected in the file on the host, and vice verse.

Finally, all VMs (i.e, "nodes") are started with the same IVSHMEM stanza.
Thus they all share that pseudo-physical memory space.  That is the essence
of fabric-attached memory emulation.

## The Librarian File System (LFS)

WIP
