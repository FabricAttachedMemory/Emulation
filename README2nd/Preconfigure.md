## Pre-Configuration for the script

Prior experience with the QEMU/KVM suite and virsh command is useful but not
absolutely required.  Before you can run the script some conditions need to
satisfied:

* Operating system revision and package
* Selection of an output "artifact" directory
* Environment variables that control the script

### OS and extra packages

emulation_configure.bash must be run in a Debian environment.  Debian Stretch (9.2 and later) have been tested recently, as has Ubuntu 16 and 17.

Install packages for the commands __vmdebootstrap, sudo, and virsh__.  The actual package names may differ depending on your exact distro.

### Artifact directory and the FAME IVSHMEM backing file

The node emulated FAM is backed on the QEMU host by a file in the host file
system.  Thus the emulated FAM is persistent to VM reboots.  This file must
be created before running the configuration script.  All node VMs will share 
that one file so the global shared address space effect is realized.

Additionally, the script will generate files (node images, logs, etc).   
While it's possible to select different directory paths for different 
artifacts, you are encouraged to let everything exists under one directory.

First choose a location for all these files; a reasonable place is $HOME/FAME.  Export the following environment variable then create the directory:

```
    $ export FAME_DIR=$HOME/FAME
    $ mkdir $FAME_DIR
```

The backing store file must exist before running the script as it is scanned
for size.  The file must be "big enough" to hold the expected FAM data from all
nodes (VMs).  The size must be between 1G and 256G and must be a power of 2.
There can be a little trial and error to get it right for your usage,
but changing it and re-running the script is trivial.  The file is referenced
by the $FAME_FAM variable.  Assuming it's going to live in $FAME_DIR:

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
| FAME_DIR | All resulting artifacts are located here, including disk images and declaration files. This is a good place to create $FAME_FAM. | Must be explicitly set |
| FAME_FAM | The "backing store" for the Global NVM seen by the nodes; it's the file used by QEMU IVSHMEM. | Must be explicitly set |
| FAME_HOSTBASE | The base for named entities (VM file names, network and hostnames, commands) | "node" |
| FAME_KERNEL | The kernel package pulled from the $FAME_L4FAME repo. | linux-image-4.14.0 |
| FAME_L4FAME | The auxiliary L4FAME repo.  The default global copy is maintained by HPE but there are ways to build your own. | http://downloads.linux.hpe.com/repo/l4fame/Debian |
| FAME_MIRROR | The primary Debian repo used by vmdebootstrap. | http://ftp.us.debian.org/debian |
| FAME_OCTETS123 | The first three octets of the virtual network.  It should be RFC-1918 compliant. | 192.168.42 |
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
FAME_HOSTBASE=node
FAME_KERNEL=linux-image-4.14.0-fame
FAME_L4FAME=http://downloads.linux.hpe.com/repo/l4fame/Debian
FAME_MIRROR=http://ftp.us.debian.org/debian
FAME_OCTETS123=192.168.42
FAME_PROXY=
FAME_USER=l4mdc
FAME_VCPUS=2
FAME_VDRAM=786432
FAME_VERBOSE=
FAME_VFS_GBYTES=6
```

Variables can be set and exported for use prior to running the script.  
When it is run with an argument to create VMs, the values will be stored in
$FAME_DIR/BASE_env.sh.  This file can be sourced to recreate the desired
runtime environment at a later time.

