# Emulation of Fabric-Attached Memory for The Machine

Experience the developer environment of tomorrow's hardware _today_.  The Machine from Hewlett Packard Enterprise offers a new paradigm in memory-centric computing.  While the prototype hardware announced in 2016 will not be generally available, you can experiment with Fabric-Attached Memory (FAM) right now.

## Description

The Machine is a homogenous node-based cluster of SoCs running Linux with standard direct-attached DRAM.  All nodes also provide a range of memory attached to a foreign fabric (actually a Gen-Z precursor).   All segments of FAM are connected together and all of FAM is visible to all nodes in a shared fashion.  These statements should make much more sense after [reading the background material on the wiki.](https://github.com/FabricAttachedMemory/Emulation/wiki)

The shared global address space is manipulated from each node via the Linux filesystem API.  A new file system, the Librarian Filesystem Suite (LFS), allows familiar operations (open/create/allocate/delete) to request chunks of FAM.  Finally, the file can be memory-mapped via mmap(2) and deliver load-store operations directly to FAM without the OS or another API.  This is the promise of Memory-Driven Computing.  A daemon on each node communicates with a single server process to realize a global, distributed file system across nodes of The Machine.

Fabric-Attached Memory Emulation (FAME) is an environment that can be used to explore this new paradigm of The Machine.  FAME employs QEMU virtual machines (VMs) to be the "nodes" in The Machine.  A feature of QEMU, Inter-Virtual Machine Shared Memory (IVSHMEM), is configured across all the node VMs so they see a shared, global memory space.  This emulation is a "good-enough" approximation of real hardware to accomodate large amounts of software development on the nodes.  [Read more about emulation here](https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-and-Simulation) and [QEMU/FAME here](https://github.com/FabricAttachedMemory/Emulation/wiki/Emulation-via-Virtual-Machines).

## 1. Configure your Debian-based system to run the script

In the discussions that follow, the phrase "QEMU host" refers to your
primary system on which you have downloaded this repo.  You will generate
VM images and run them under QEMU on this "QEMU host".   The VM images
represent "nodes" in The Machine, and the phrases "nodes" and "VMs" should
be considered equivalent.

The primary script in this repo is ``emulation_configure.bash``.   It will
create the necessary virtual network, VM bootable images, and control scripts.
The script is mostly driven by a set of environment variables, all of
which start with the prefix **FAME_**.  If you run the script without
arguments it lists the current value of all those variables.

emulation_configure.bash must be run in a Debian environment.  The following
releases have been shown to work:
* Debian Stretch (9.2 and later) 
* Ubuntu 16, 17, and 18

Other distros have been used "indirectly"; scroll to the bottom of this page
for details.

Prepare your system [as described here](README2nd/Preconfigure.md).

## 2. Running the script

After setting the appropriate environment variables your login user on
the QEMU host, run the script.   It takes the desired number of VMs as its
sole argument.

    $ ./emulation_configure.bash n

    
Early on you'll be prompted for your password for "sudo" as several of
the commands in the script need root privilege.  If you want to run the 
script via sudo, be sure to preserve the environment variables with -E:

    $ sudo -E ./emulation_configure.bash n

The script creates many files in **$FAME_DIR** whose names are based off the
**$FAME_HOSTBASE** variable.  For example, if you use the default "node",
all the files in **$FAME_DIR** will start with "node_" and the virtual
network will be named "br_node".  Thus it's easy to support multiple FAME
clusters on one QEMU host.

[This document has more detail on the actions and artifacts](README2nd/BehindTheScenes.md).

When emulation_configure.bash completes successfully, you can declare the
nodes to the libvirt subsystem:

    cd $FAME_DIR
    ./node_virsh define

## 3. Configure the Librarian File System (LFS)

The nodes (VMs) participate in a distributed file system.  That file system
is coordinated by a single master daemon known as the Librarian which runs
on a host (other than a VM).  In the FAME setup, the Librarian can run on the
QEMU host.  Before starting the nodes, the Librarian must be [configured as
discussed in this document.](README2nd/Librarian.md).

## 4. Start the nodes

Once the librarian is running, you can start the nodes (if you've already
declared them as shown in step 2):

    cd $FAME_DIR
    ./node_virsh start

You could also run individual "virsh" commands to start nodes, or run the
GUI virt-manager.

The root password for all nodes is "iforgot".  A normal user **$FAME_USER**
(default "l4mdc", also password "iforgot") exists and is enabled as a full
"sudo" account.  The normal user is configured with a phraseless ssh keypair
expressed in templates/id_rsa.nophrase (the private key).  You can grab this
file and use it in your personal .ssh/config setup on your QEMU host.

Networking should be active on eth0.  /etc/hosts is set up for BASE01
through BASEXX.  The QEMU host system is known on each node by its own
hostname and the name "torms"; see the section on the Librarian.  sshd is
set up on every node for inter-node access as well as access from the host.

A reasonable development environment (gcc, make) is available at first boot.  "apt" and "aptitude" are configured to allow package installation and updates per the **$FAME_MIRROR**, **$FAME_L4FAME**, and **$FAME_PROXY** settings above.

## 5. Networking and DNS for the nodes

Each VM guest Linux gets its IP address via DHCP to the corresponding dnsmasq
of its virtual intranet.  **$FAME_OCTETS123** defines the first three octets
of the RFC1914 address; the default is "192.168.42" .

For now, 

* BASE01 == 3OCTETS.1 (ie, node01 == 192.168.42.1)
* BASE02 == 3OCTETS.2 (ie, node02 == 192.168.42.2)

and so on.  There are several ways to resolve node names from the QEMU host:

1. (Simplest) Manually add them to the the QEMU host's "/etc/hosts".
1. For a small number of nodes, add the Host/Hostname to $HOME/.ssh/config.
A change is needed anyway to utilize id_rsa.nophrase.
1. With resolvconf, NetworkManager, and systemd-resolved all vying for attention, true DNS-based resolution is left as an exercise to the reader.

You can ssh to the node as the normal **$FAME_USER**.  If you edit your
$HOME/.ssh/config file correctly using the id_rsa.nophrase private key the 
ssh occurs without confirmation.

---

## Running emulation_configure.sh on non-Debian Linux hosts

[This document explains](README2nd/Docker.md) how to execute
emulation_configure.bash in a Docker container on your preferred host
system (such as RedHat or SLES).  The resulting (Debian) VMs
and other files will still be left in **$FAME_DIR** as expected.

For the most part you need to configure your host as outlined in steps 1-5
above, making distro-appropriate changes.

## Manual setup for SuSE LEAP 15 VMs

<code>emulation_configure.bash</code> creates VMs running Debian.  If you'd
prefer a set of VMs running SuSE LEAP 15, [these instructions should guide
you through it](README2nd/SuSELEAP15.md).

---

## Running FAME on non-Linux host systems: Nested VMs

1. Install a hypervisor that will support recent Debian/Ubuntu distros
   * For Windows, use VMware Workstation.  [More details are given here](README2nd/Windows.md).
   * For Mac OSX, use Oracle VirtualBox.
1. Create a Debian/Ubuntu VM under the hypervisor as the "FAME host"
1. Enter the FAME host, git clone the Emulation repo and follow the main instructions starting at "1. Configure your Debian host..."

