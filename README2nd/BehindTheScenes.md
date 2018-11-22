### Behind the scenes

In the following discussion, BASE is the value of **$FAME_HOSTBASE** which
is "node" by default.   Thus "BASEXX.qcow2" would refer to a file like
node03.qcow2.

emulation_configure.bash performs the following actions:

1. Validates the host environment, ensuring commands are installed, verifying file space and internal consistency.
1. Creates a virtual intranet called "br_node" (br is short for "bridge") which
    * Uses NAT to bridge the intranet to the host system's external network.
    * Links all emulated VM "nodes" together on that intranet
    * Provides DHCP services via dnsmasq and DNS resolution for names like "BASE02"
1. Uses vmdebootstrap(1m) to create a new disk image (file) that serves as
the "golden image" for subsequent use.  This is the step that pulls from
**$FAME_MIRROR** possibly using **$FAME_PROXY**. This template file is a
raw disk QEMU image name BASE_image.raw.  The default size of 6G
(**$FAME_VFS_GBYTES**)
will leave about 4.5 G of empty space, more than enough for a non-graphical
Linux development system.  If your host system is limited on disk space,
try reducing **$FAME_VFS_GBYTES** and recreating the images.
1. Augments the *apt* environment on the golden image to also use **$FAME_L4FAME**, then installs the FAME packages such as [the LFS daemon](Librarian.md).
1. Copy the template image for each VM and customize it (hostname, /etc/hosts,
etc etc etc).  The raw image is then converted to a qcow2 (copy-on-write) which shrinks its size down to 800 megabytes.  That will grow with use, limited by **$FAME_VFS_GBYTES**.  Each node gets its own image, BASE01.qcow2, BASE02.qcow2, etc.
1. Emits libvirt XML node definition files and and a script to load/start/stop/unload them from libvirt/virt-manager.  The XML files contain stanzas necessary to create the IVSHMEM connectivity to **$FAME_FAM**.

### Artifacts

The following files will be created in **$FAME_DIR** after a successful run.

| Artifact | Description |
|----------|-------------|
| BASEXX.qcow2 | The disk image file for VM "node" XX |
| BASEXX.xml | The "domain" defintion file for "node" XX, loaded into virt-manager via "virsh define nodeXX.xml" |
| BASE_dpkg.list | All Debian packages included in each node. |
| BASE_env.sh | A shell script snippet containing the FAME_XXX values from the last run of emulation_configure.bash. |
| BASE_fame.in | The Librarian configuration file (read below) |
| BASE_log | Trace file of all steps by emulation_configure.bash |
| BASE_log.vmd | Output from vmdebootstrap |
| BASE_network.xml | libvirt definition file for the assigned virtual network |
| BASE_template.img | Undifferentiated file-system golden image from vmdebootstrap. |
| BASE_virsh.sh | Shell script to to "define", "start", "stop", "destroy", and "undefine" all VM "nodes" |

