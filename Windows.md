Assuming you have an HPE-installed Windows system (laptop or desktop) you can run FAME on your box.

1. Create a Debian VM under VMware for Windows
1. Install and build [FAME as normal under Debian](https://github.com/FabricAttachedMemory/Emulation)

## System requirements (above the base Windows installation)
Resources needed for the "host" Debian VM plus the nested VMs (one per "node")
1. CPU: Try to limit 1 "node" VM per actual core
2. RAM: 2 GB for host VM plus 2 GB per "node" VM
3. Free disk: 4 GB for host VM plus 6 GB scratch space plus 2 GB per "node" VM (default value of $FAME_VFS_BYTES=6)

## Prepare HPE Windows System
### Install software from myIT Software Center
1. VMware Workstation
1. Reflection w/SP5
### Obtain Debian 9.x (Stretch) network install ISO
1. https://www.debian.org/CD/netinst/ and choose the ["amd64" via http option](https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-9.3.0-amd64-netinst.iso)

## Create "Host" VM under VMware
1. Start VMware and use the wizard to create a new VM
1. __Guest OS Installation__: installer disk image file, choose the "debian-9.x.y-amd64-netinst.iso" in your Downloads folder
1. __Select a Guest OS__: Choose Linux, Debian 64-bit, with the highest release available (ie, 8.x is fine)
1. __Name the Virtual Machine__: whatever you like, but as it will function as the ToRMS, that might be a good name.
1. __Specify disk capacity__:  the default 20G is sufficient for up to four "node" VMs, assuming you do NOT put a desktop environment on the host VM.  Single/multiple files is not important, use the default.
1. __Ready to create Virtual Machine__: review your choices, the default networking is NAT (use it).  There's no reason to customize any hardware.

## Customize the "Host" VM on first boot
1. Use the whole disk, LVM and partitioning is not needed
    1. Advanced use: repartition the (virtual) drive to remove swap space
1. Normal user should be "l4mdc"
1. Suggested password is "iforgot" for both root and l4mdc.
1. When it reboots, log in.

Finally, install and build [FAME as normal under Debian](https://github.com/FabricAttachedMemory/Emulation)
