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

| Variable | Purpose |
|----------|---------|
| VERBOSE |Normally the script is fairly "quiet", only emitting cursory progress messages.  If VERBOSE set to any value (like "yes"), step-by-step operations are sent to stdout and the file $TMPDIR/fabric_emulation.log Default: not set|
| TMPDIR | All resulting artifacts are located here.  A size check is done to ensure there's enough space.  If that check fails, either free up space or set TMPDIR to another directory.  Default: /tmp|
| MIRROR | The script builds VM images by pulling packages from Debian repo.  Default: http://ftp.us.debian.org/debian|
| PROXY | Any proxy needed to reach $MIRROR.  Default: not set|

These variables must be seen in the script's environment so use the "-E"
command if invoking sudo directly:

    $ export MIRROR=http://a.b.com/debian
    $ export VERBOSE=yes
    $ emulation_configure.bash n

works, as well as

    $ sudo -E emulation_configure.bash n

or

    $ sudo VERBOSE=yes MIRROR=http://a.b.com/debian emulation_configure.bash n

## Behind the scenes

emulation_configure.bash performs the following actions:

1. Validates the host environment, starting with execution as root or sudo.  While it doesn't explicitly limit its execution to Debian Jessie, it does check for commands that may not exist on other Debian variants.  Other things are checked like file space and internal consistency.
1. Creates a libvirt virtual bridged network called "fabric_emul" which
  2. Provides DHCP services via dnsmasq
  2. Links all emulated VM "nodes" together on an intranet (ala The Machine)
  2. Uses NAT to connect the intranet to the host system's external network.
1. Uses vmdebootstrap(1m) to create a new disk image (file) that serves as the template for each VM's file system.  This is the step that pulls from the Debian mirror (see MIRROR and PROXY above).  Most of the configuration is specified in the file fabric_emulation.vmd, with several options handled in the shell script.  This template file is a raw disk image yielding about eight gigabytes of file system space for a VM, more than enough for a non-graphical Linux development system.
1. Copy the template image for each VM and customize it (hostname, /etc/hosts, /etc/resolv.conf, root and user "fabric").  The raw image is then converted to a qcow2 (copy-on-write) which shrinks its size down to 800 megabytes.  That may grow with use.
1. Emits an invocation script which may be used to start all VMs.  That script is in $TMPDIR/fabric_emulation.bash.  The qemu commands contain stanzas necessary to create the IVSHMEM connectivity (see below).

## Artifacts

The following files will be created in $TMPDIR after a successful run.

| Artifact | Description |
|----------|-------------|
| fabricN.qcow2 | The disk image file for VM "node" N |
| fabric_emulation.bash | Shell script to start all VM "nodes" |
| fabric_emulation.log | Trace file of all steps by emulation_configure.bash |
| fabric_template.img |	Pristine (un-customized) file-system image of vmdebootstrap.  This is a partitioned disk image and is not needed to run the VMs. |
| fabric_template.tar |	Tarball of the root filesystem on fabric_template.img |

## VM Guest Environment

The root password is "aresquare".  A single normal user also exists, "fabric", with password "rocks", and is enabled as a full "sudo" account.

Networking should be active on eth0.  /etc/hosts is set up for "nodes" fabric1 through fabric4.  The host system is known by its own hostname and the name "vmhost".   sshd is set up on every node for inter-node access as well as access from the host.

"apt" and "aptitude" are configured to allow package installation and updates per the MIRROR and PROXY settings above.

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

The VM "physical" address space is backed on the host by a POSIX shared memory object.  This object is visible on the host in the file /dev/shm/fabric_em.  Anything done to the address space on the VM is reflected in the file on the host, and vice verse.

Finally, all VMs (i.e, "nodes") are started with the same IVSHMEM stanza.  Thus they all share that pseudo-physical memory space.  That is the essence of fabric-attached memory emulation.

## Hello, world!

As the IVSHMEM address space is physical and unmapped, a kernel driver is needed to access it.   Fortunately there's a shortcut in the QEMU world.  The IVSHMEM mechanism also makes a file available on the VM side under /proc/bus/pci.   In general the apparent PCI address might vary between VMs, but since they all use a simple stanza, all VMs see that file at

    /sys/bus/pci/devices/0000:00:04.0/resource2

If a user-space program on the VM opens and memory-maps this file via mmap(2), memory accesses go to the pseudo-physical address space shared across all VMs.  This file can only be memory-mapped on the VM; read and write is not implemented.To simplify the program, the resource2 file is symlinked at /mnt/fabric_emulation.

A simple demo program is copied to the home directory of the "fabric" user on each VM.  Compile it on one node and run it (using sudo to execute).  Then go to the host VM and "cat /dev/shmem/fabric_em".  You should see uname output from the node.  Those same contents will appear to all other nodes, too (if you write a program that loads from the shared space instead of storing to it).

What about syncing between nodes?  That is left as an exercise to the reader, as it would be in any setup involving a shared global resource.  Have fun :-)
