## Creating VMs running openSUSE LEAP 15

SuSE offers a bootable image of a Tumbleweed/openSUSE/SLES hybrid called LEAP:
[https://en.opensuse.org/Portal:Leap](https://en.opensuse.org/Portal:Leap).
That can be used as a basis for FAME-compatible VMs.

Your host system still needs to be configured to run the Librarian, but
there are now SLES packages for that on the [HPE Software Delivery Repo](http://downloads.linux.hpe.com/SDR/repo/l4fame).

### Configuring your (SLES) host

If running SLES15 you can add the HPE SDR repo:

<code> # zypper zypper addrepo --no-gpgcheck --refresh https://downloads.linux.hpe.com/SDR/repo/l4fame/SLES/ FAME</code>

Or grab the following two packages and install them manually:

* [python3-tm-librarian-1.35-5.noarch.rpm](http://downloads.linux.hpe.com/SDR/repo/l4fame/SLES/python3-tm-librarian-1.35-5.noarch.rpm)
* [tm-librarian-1.35-5.noarch.rpm](http://downloads.linux.hpe.com/SDR/repo/l4fame/SLES/tm-librarian-1.35-5.noarch.rpm)

Configure the Librarian database in /var/hpetm/librarian.db as described in prior documentation on this site.

---

### Creating the first LEAP 15 VM

The steps are numerous and rough as this is new (May 2019).  Better
instructions will come with use and feedback, and perhaps some automation
per demand.  Or submissions :-)

1. Install the qemu-kvm, libvirt and virt-manager suites on your host system.  A basic familiarity with these tools is required.  Insure the "default" virtual network is up and running.
1. From (https://software.opensuse.org/distributions/leap)[https://software.opensuse.org/distributions/leap] download the "JeOS x86_64" image for KVM/Xen image (about 250M).  It will be a filename like "openSUSE-Leap-15.0-JeOS.x86_64-15.0.1-kvm-and-xen-Current.qcow2"; this should be treated as a source raw image.
1. Copy the raw image to a working file like "leap01.qcow2" which will be used as the first node.
1. Install the image under libvirt:
```shell
# virt-install --connect  qemu:///system --name leap01 \
  --virt-type kvm --os-variant sled12 \
  --memory 1024 --cpu host --vcpus 2 \
  --network network=default,mac=48:50:42:01:01:01 \
  --video qxl --channel spicevmc \
  --import --disk ./leap01.qcow2
```
The MAC address is critical, use it exactly as shown.  Memory and VCPU count
can be adjust to suit your taste.

---

### First boot of the (first) LEAP 15 VM

1. Run the image and get a console to it.  virt-manager is the easiest way.
1. Answer the questions, watch out for the timezone (default is UTC).
1. Log in as root.  Create a .bashrc file to your liking.
1. If you need http_proxy and/or https_proxy variables, put them in /etc/environment
1. Edit /etc/hostname and leave one line that says "leap01"
1. Edit /etc/hosts and add two lines:<br><code>
   127.0.1.1        leap01<br>
   192.168.122.1 torms</code>
1. Reboot the VM
1. Log back in, verifying the new hostname.  Run<br><code>
   zypper refresh</code><br>
   to verify networking and any proxies.
1. Add a few more packages for the next steps:<br><code>
   zypper install spice-vdagent pciutils 
1. Shutdown the VM, insure it's truly stopped at virt-manager or "virsh list"

---

### Add a host FAM file to the VM configuration

1. Create the backing store file for FAM, such as <br><code>
   truncate -s 512M $HOME/FAM</code><br>
   Determination of the size is explained in "Configuring the Librarian" on the landing README.md.
1. Edit the image domain XML as in "virsh edit leap01"
1. Replace the very first line with<br><code>
   &lt;domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'&gt;
   </code>
1. Go to the end of the file.  After the closing &lt;/devices&gt; and
before the closing &lt;/domain&gt; insert the following six lines:<br><code>
  &lt;qemu:commandline><br>
    &lt;qemu:arg value='-object'/><br>
    &lt;qemu:arg value='memory-backend-file,mem-path=/home/you/FAM,size=512M,id=FAM,share=on'/><br>
    &lt;qemu:arg value='-device'/><br>
    &lt;qemu:arg value='ivshmem-plain,memdev=FAM'/><br>
  &lt;/qemu:commandline><code>
1. Boot the VM and login as root.  Run lspci -v and look for lines like this:<pre>00:09.0 RAM memory: Red Hat, Inc. Inter-VM shared memory (rev 01)
	Subsystem: Red Hat, Inc. QEMU Virtual Machine
	Physical Slot: 9
	Flags: fast devsel
	Memory at fc05a000 (32-bit, non-prefetchable) [size=256]
	Memory at c0000000 (64-bit, prefetchable) [size=512M]
</pre>
Some numbers may change but the final line should show size=512M.

---

### Adding Librarian kernel and packages

Assuming you've added the FAME repo as outlined above,

1. zypper install --from FAME kernel
1. Reboot.  Run "modinfo tmfs" and insure it doesn't say "tmfs not found"
1. mkdir /lfs
1. zypper install tm-lfs tm-libfuse
1. ldconfig /usr/lib/x86_64-linux-gnu
1. ldconfig -p | grep tmfs and insure files are found
1. Insure the Librarian is running on your host system
1. service tm-lfs start
1. df /lfs and insure it makes sense

---

### Cloning more nodes from leap01

I have not actually tried these steps yet...

1. Shut down leap01
1. cd to the directory holding the leap01.qcow2
1. virt-clone -o leap01 -n leap02 -f leap02.qcow2 -m=48:50:42:02:02:02
1. Boot the new leap02, log in, and change /etc/hosts and /etc/hostname
1. Reboot, insure the new hostname took
1. service tm-lfs start

