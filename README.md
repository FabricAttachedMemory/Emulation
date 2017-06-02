# Emulation of Fabric-Attached Memory for The Machine

Experience the developer environment of next year's hardware _today_.  The Machine from Hewlett Packard Enterprise prototype offers a new paradigm in memory-centric computing.  While the hardware won't be available until 2016, you can experiment with fabric-attached memory right now.

## Description

This repo delivers a script to create virtual machine file system images directly from a Debian repo.  VMs are then customized and configured to emulate the fabric-attached memory of The Machine.  Those statements should make much more sense after [reading the background material on the wiki.](https://github.com/FabricAttachedMemory/Emulation/wiki)

Fabric-Attached Memory Emulation is an environment that can be used to explore the new architectural paradigm of The Machine.  Some knowledge of The Machine architecture is useful to use this suite, but it actually ignores the minutiae of the hardware.  Reasonable fluency with the QEMU/KVM/libvirt/virsh suite is highly recommended.

The emulation employs QEMU virtual machines performing the role of "nodes" in The Machine.  Inter-Virtual Machine Shared Memory (IVSHMEM) is configured across all the "nodes" so they see a shared, global memory space.  This space can be accessed via mmap(2) and will behave just the the memory centric-computing on The Machine.

## Setup and Execution

The emulation configurator script, *emulation_configure.bash*, is written for Debian 8.x (Jessie/stable).  It should have the packages necessary for x86_64 virtual machines: qemu-system-x86_64 and libvirtd-bin should bring in everything else.  You also need the vmdebootstrap package.

After cloning this repo, run the script; it takes the desired number of VMs as its sole argument.  Several of the commands in the script must be run as root; you can run the entire script as root (or sudo).  You can also run the script as a normal user: all necessary commands are run internally under "sudo".

Several environment variables can be set (or exported first) that affect the operation of emulation_configure.bash:

| Variable | Purpose | Default |
|----------|---------|---------|
| FAME_FAM | The "backing store" for the Global NVM seen by the nodes; it's the file used by QEMU IVSHMEM. | REQUIRED! |
| FAME_MIRROR | The script builds VM images by pulling packages from Debian repo. | http://ftp.us.debian.org/debian |
| FAME_OUTDIR | All resulting artifacts are located here.  A size check is done to ensure there's enough space.  If that check fails, either free up space or set FAME_OUTDIR to another directory. | /tmp |
| FAME_PROXY | Any proxy needed to reach $FAME_MIRROR. | $http_proxy |
| FAME_VERBOSE |Normally the script is fairly "quiet", only emitting cursory progress messages.  If VERBOSE set to any value (like "yes"), step-by-step operations are sent to stdout and the file $ARTDIR/fabric_emulation.log | unset |

These variables must be seen in the script's environment so use the "-E"
command if invoking sudo directly:

    $ export FAME_MIRROR=http://a.b.com/debian
    $ export FAME_VERBOSE=yes
    $ emulation_configure.bash n

works, as well as

    $ sudo -E emulation_configure.bash n

or

    $ sudo FAME_VERBOSE=yes FAME_MIRROR=http://a.b.com/debian emulation_configure.bash n

Note: *$TMPDIR* is a "reserved" by the OS environment variable that will be cleaned out by *glibc* when you run *sudo -E*,
therefore it will not be picked up by the program ([link](http://serverfault.com/questions/478741/sudo-does-not-preserve-tmpdir)). If you want to use *$TMPDIR* you should run it as follows:

    $ sudo -E TMPDIR=/path/to/folder/ VERBOSE=yes MIRRORA=your/debian/mirror/ emulation_configure.bash n
    

## Behind the scenes

emulation_configure.bash performs the following actions:

1. Validates the host environment, starting with execution as root or sudo.  While it doesn't explicitly limit its execution to Debian Jessie, it does check for commands that may not exist on other Debian variants.  Other things are checked like file space and internal consistency.
1. Creates a libvirt virtual bridged network called "node_emul" which
  2. Provides DHCP services via dnsmasq
  2. Links all emulated VM "nodes" together on an intranet (ala The Machine)
  2. Uses NAT to connect the intranet to the host system's external network.
1. Uses vmdebootstrap(1m) to create a new disk image (file) that serves as the template for each VM's file system.  This is the step that pulls from the Debian mirror (see MIRROR and PROXY above).  Most of the configuration is specified in the file fabric_emulation.vmd, with several options handled in the shell script.  This template file is a raw disk image yielding about eight gigabytes of file system space for a VM, more than enough for a non-graphical Linux development system.
1. Copy the template image for each VM and customize it (hostname, /etc/hosts, /etc/resolv.conf, root and user "l4tm").  The raw image is then converted to a qcow2 (copy-on-write) which shrinks its size down to 800 megabytes.  That may grow with use.
1. Emits libvirt XML node definition files and scripts to load/start/stop/unload them from libvirt/virt-manager.  Those files are all in $FAME_OUTDIR.  The XML files contain stanzas necessary to create the IVSHMEM connectivity (see below).

## Artifacts

The following files will be created in $FAME_OUTDIR after a successful run.  Note: FAME_OUTDIR was originally TMPDIR, but that variable is suppressed by glibc on setuid programs which breaks under certain uses of sudo.

| Artifact | Description |
|----------|-------------|
| nodeXX.qcow2 | The disk image file for VM "node" XX |
| nodeXX.xml | The "domain" defintion file for "node" XX, loaded into virt-manager via "virsh define nodeXX.xml" |
| node_emulation.log | Trace file of all steps by emulation_configure.bash |
| node_template.img |	Pristine (un-customized) file-system image of vmdebootstrap.  This is a partitioned disk image and is not needed to run the VMs. |
| virsh_nodes.sh | Shell script to to "define", "start", "destroy" (stop), and "undefine" all VM "nodes" |

## VM Guest Environment

The root password is "iforgot".  A single normal user also exists, "l4tm", with password "iforgot", and is enabled as a full "sudo" account.  The l4tm user is configured with a phraseless ssh keypair expressed in id_rsa.nophrase (the private key).

Networking should be active on eth0.  /etc/hosts is set up for "nodes" node01 through nodeXX.  The host system is known by its own hostname and the name "torms".   sshd is set up on every node for inter-node access as well as access from the host.

"apt" and "aptitude" are configured to allow package installation and updates per the FAME_MIRROR and FAME_PROXY settings above.

A reasonable development environment (gcc, make) is available.  This can be used to compile the simple "hello world" program found in the home directory of user "fabric".

## IVSHMEM connectivity between all VMs

Memory-centric computing in a The Machine is done used via memory accesses similar to those used with legacy memory-mapping.  Emulation provides a resource for such [user space programming via IVSHMEM](https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-via-Virtual-Machines).  A typical QEMU invocation line looks something like this: 

    qemu-system-x86_64 -enable-kvm \
        -net bridge,br=fabric_em,helper=/usr/lib/qemu/qemu-bridge-helper \
        -net nic,macaddr=52:54:48:50:45:02,model=virtio \
        -device ivshmem,shm=fabric_em,size=1024 \
        /tmp/fabric2.qcow2

Fabric-Attached Memory Emulation is achieved via the stanza

    -device ivshmem,shm=fabric_emulation,size=1024

On the VM side, this creates a pseudo-PCI device with a memory base address register (BAR) of size 1024 megabytes (one gigabyte).  It can be seen in detail via "lspci -vv".  This is presented to the VM kernel as "live", unmapped physical address space.

The VM "physical" address space is backed on the host the file $FAME_FAM.  This file must exist before invoking emulation_configure.bash, and its size must be a power of two.  Anything done to the address space on the VM is reflected in the file on the host, and vice verse.

Finally, all VMs (i.e, "nodes") are started with the same IVSHMEM stanza.  Thus they all share that pseudo-physical memory space.  That is the essence of fabric-attached memory emulation.

## Hello, world!

As the IVSHMEM address space is physical and unmapped, a kernel driver is needed to access it.   Fortunately there's a shortcut in the QEMU world.  The IVSHMEM mechanism also makes a file available on the VM side under /proc/bus/pci.   In general the apparent PCI address might vary between VMs, but since they all use a simple stanza, all VMs see that file at

    /sys/bus/pci/devices/0000:00:04.0/resource2

If a user-space program on the VM opens and memory-maps this file via mmap(2), memory accesses go to the pseudo-physical address space shared across all VMs.  This file can only be memory-mapped on the VM; read and write is not implemented.To simplify the program, the resource2 file is symlinked at /mnt/fabric_emulation.

A simple demo program is copied to the home directory of the "fabric" user on each VM.  Compile it on one node and run it (using sudo to execute).  Then go to the host VM and "cat $FAME_FAM".  You should see uname output from the node.  Those same contents will appear to all other nodes, too (if you write a program that loads from the shared space instead of storing to it).

What about syncing between nodes?  For that you need the Librarian, which will be explained shortly...
