#!/bin/bash

# Copyright 2015-2017 Hewlett Packard Enterprise Development LP

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2  as 
# published by the Free Software Foundation.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along
# with this program.  If not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

# Configurator script for the Fabic-Attached Memory Emulation for
# The Machine from Hewlett Packard Enterprise.
# See http://github.com/FabricAttachedMemory for more details.

# Set these in your environment to override the following defaults.
# Note: ARTDIR was originally TMPDIR, but that variable is suppressed
# by glibc on setuid programs which breaks under certain uses of sudo.

export ARTDIR=${ARTDIR:-/tmp}	# ARTifact DIRectory

export FAM=${FAM:-/dev/shm/GlobalNVM}

export FAMSIZE=${FAMSIZE:-4G}

export MIRROR=${MIRROR:-http://ftp.us.debian.org/debian}

export PROXY=${PROXY:-}		# Default: no proxy override

export VERBOSE=${VERBOSE:-}	# Default: mostly quiet; "yes" overrides

###########################################################################
# Hardcoded to match content in external config files.  If any of these
# is zero length you will probably trash your host OS.  Bullets, gun, feet.

typeset -r HOSTUSERBASE=node
typeset -r PROJECT=${HOSTUSERBASE}_emulation
typeset -r LOG=$ARTDIR/$PROJECT.log
typeset -r NETWORK=${HOSTUSERBASE}_emul		# libvirt name length limits
typeset -r HPEOUI="48:50:42"
typeset -r TEMPLATE=$ARTDIR/${HOSTUSERBASE}_template.img
typeset -r TARBALL=$ARTDIR/${HOSTUSERBASE}_template.tar

export DEBIAN_FRONTEND=noninteractive	# preserved by chroot
export DEBCONF_NONINTERACTIVE_SEEN=true
export LC_ALL=C LANGUAGE=C LANG=C

###########################################################################
# Helpers

function sep() {
    SEP=". . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . ."
    echo -e "$SEP\n$*\n"
    return 0
}

# Early calls (before SUDO is set up) may not make it into $LOG
function die() {
    mount_image		# release anything that may be mounted
    echo -e "Error: $*" >&2
    echo -e "\n$0 failed:\n$*\n" >> $LOG
    [ "$VERBOSE" ] && env | sort >> $LOG
    echo -e "\n$LOG may have more details" >&2
    exit 1
}

function quiet() {
    if [ "$VERBOSE" ]; then
    	echo $*
    	eval $*
    else
    	eval $* >/dev/null 2>&1
    fi
    return $?
}

function yesno() {
    while true; do
    	read -p "$* (yes/no) ? " RSP
	[ "$RSP" = yes ] && return 0
	[ "$RSP" = no ] && return 1
    done
}

###########################################################################
# Helper for qemu-bridge-helper, contained in package qemu-system-common

function verify_QBH() {
    QBH=/usr/lib/qemu/qemu-bridge-helper	# qemu-system-common
    ACL=/etc/qemu/bridge.conf 			# ACL mechanism: allow/deny

    [ -x $QBH ] || die "$QBH is missing"
    [ `stat -c "%u:%g" $QBH` != "0:0" ] && die "$QBH is not owned by root"
    if [ `stat -c "%A" $QBH | cut -c4` != 's' ]; then
	cat << EOMSG

$QBH must be setuid root for
this script to work.  There is some concern that presents a
security hole, but running QEMU as root is worse.  See

http://wiki.qemu.org/Features-Done/HelperNetworking#Detailed_Summary

EOMSG
    	yesno "Change $QBH to setuid root"
	[ $? -eq 1 ] && echo "No configuration for you." && exit 0
	$SUDO chown root:root $QBH
	$SUDO chmod 4755 $QBH
    fi

    # Always fix $ACL whether missing entirely or just missing the entry.
    quiet $SUDO mkdir -m 755 -p `dirname $ACL`
    PATTERN="allow $NETWORK"
    quiet $SUDO grep -q "'^$PATTERN\$'" $ACL
    [ $? -ne 0 ] && echo $PATTERN | quiet $SUDO tee -a $ACL

    # "Failed to parse default acl file" if these are wrong.
    quiet $SUDO chown root:libvirt-qemu $ACL
    quiet $SUDO chmod 640 $ACL

    return 0
}

###########################################################################
# vmdebootstrap requires root, but first insure other commands exist.
# Ass-u-me coreutils is installed.

SUDO="sudo -E"

function verify_host_environment() {
    sep Verifying host environment

    # Chicken and egg: sudo has not yet been verified
    if [ -f $LOG ]; then
	PREV=$LOG.previous
	quiet rm -f $PREV
	[  $? -ne 0 ] && echo "Cannot rm $PREV, please do so" >&2 && exit 1
	quiet mv -f $LOG $LOG.previous # vmdebootstrap will rewrite it
	[ $? -ne 0 ] && echo "Cannot mv $LOG, please remove it" >&2 && exit 1
    fi
    echo -e "`date`\n" > $LOG
    chmod 666 $LOG

    # Close some obvious holes before SUDO
    unset LD_LIBRARY_PATH
    export PATH="/bin:/usr/bin:/sbin:/usr/sbin"

    [ -x /bin/which -o -x /usr/bin/which ] || die "Missing command 'which'"
    NEED="awk brctl grep losetup qemu-img sudo virsh vmdebootstrap"
    MISSING=
    for CMD in $NEED; do
	quiet which $CMD || MISSING="$CMD $MISSING"
    done
    [ "$MISSING" ] && die "The following command(s) are needed:\n$MISSING"
    if [ "$USER" = root ]; then
	SUDO_USER=${SUDO_USER:-root}
	SUDO=
    else
    	sudo echo || die "sudo access is needed by this script."
	MAYBE=`$SUDO env | grep SUDO_USER`
	[ "$MAYBE" ] && eval $MAYBE
	SUDO_USER=${SUDO_USER:-root}
    fi

    LOOPS=`$SUDO losetup -al | wc -l`
    [ $LOOPS -gt 0 ] && die \
    	'losetup -al shows active loopback mounts, please clear them'

    set -- `qemu-system-x86_64 -version`
    [ "$4" != "2.6.0" ] && die "qemu is not version 2.6.0"
    verify_QBH

    # Space for 2 raw image files, the tarball, all qcows, and slop
    [ ! -d "$ARTDIR" ] && die "$ARTDIR is not a directory"
    let GNEEDED=16+1+$NODES+1
    let KNEEDED=1000000*$GNEEDED
    TMPFREE=`df "$ARTDIR" | awk '/^\// {print $4}'`
    [ $TMPFREE -lt $KNEEDED ] && die "$ARTDIR has less than $GNEEDED G free"

    return 0
}

###########################################################################
# libvirt / virsh / qemu / kvm stuff

function libvirt_bridge() {
    sep Configure libvirt network bridge \"$NETWORK\"

    XML=$PROJECT.net.xml
    [ ! -f $XML ] && die "Missing local file $XML"

    # Some installations set up LIBVIRT_DEFAULT, but the virsh man page
    # says LIBVIRT_DEFAULT_URI.  Get the deprecated version, too..
    export LIBVIRT_DEFAULT="${LIBVIRT_DEFAULT:-qemu:///system}"
    export LIBVIRT_DEFAULT_URI=$LIBVIRT_DEFAULT
    export LIBVIRT_DEFAULT_CONNECT_URI=$LIBVIRT_DEFAULT

    export VIRSH_DEBUG=0
    export VIRSH_LOG_FILE=$LOG
    VIRSH="$SUDO virsh"
    quiet $VIRSH connect
    [ $? -ne 0 ] && die "'virsh connect' failed"
    $VIRSH net-list --all | grep -q '^ Name.*State.*Autostart.*Persistent$'
    [ $? -ne 0 ] && die "virsh net-list command is not working as expected"

    for CMD in net-destroy net-undefine; do
	quiet $VIRSH $CMD $NETWORK
	sleep 1
    done

    # virsh will define a net with a loooong name, but fail on starting it.
    quiet $VIRSH net-define $XML
    [ $? -ne 0 ] && die "Cannot define the network $NETWORK:\n`cat $XML`"

    for CMD in net-start net-autostart; do
	quiet $VIRSH $CMD $NETWORK
    	[ $? -ne 0 ] && die "virsh $CMD $NETWORK failed"
    done

    return 0
}

###########################################################################
# Two nagging bugs kept /etc/kernel/postinst.d/initramfs-tools from working.
# That calls update-initramfs and update-grub (as do other admin tools).
# They all boil down to run-parts scripts in /etc/grub.d.
# I had been directly using "mount -oloop,offset=1M "$LOCALIMG" $MNT"
# whereas vmdebootstrap and my cmdline use kpartx.  The direct method
# yields a root device of /dev/loop0, whereas kpartx root device is
# /dev/mapper/loop0.  When grub-mkconfig is finally invoked,
# /etc/grub.d/00_header: chain calls grub-probe a lot to finally find the
#	image $TEMPLATE (/tmp/node_template.img).  Since that file doesn't
#	exist in the image, grub-probe dies with "Cannot find canonical...".
#	However the kpartx method gives up /dev/dm-X, so it's happy without
#	spoofing the file.
# /etc/grub.d/10_linux: exits early and grabs no kernels for
#	/boot/grub/grub.cfg if the root device is of the form "/dev/loop".
# /etc/grub.d/30_os-prober: package os-probe is not downloaded in these
#	minimal debootstraps, but I don't care for this effort.
# So using kpartx kills the two birds with one stone.

[ ! "$PROJECT" ] && die PROJECT is empty
typeset -r MNT=/mnt/$PROJECT
BINDFWD="/proc /sys /run /dev /dev/pts"
BINDREV="`echo $BINDFWD | tr ' ' '\n' | tac`"
LAST_KPARTX=

function mount_image() {
    if [ -d $MNT ]; then	# Always try to undo it
    	for BIND in $BINDREV; do
		[ -d $BIND ] && quiet $SUDO umount $MNT$BIND
	done
    	quiet $SUDO umount $MNT
	[ "$LAST_KPARTX" ] && quiet $SUDO kpartx -d $LAST_KPARTX
	LAST_KPARTX=
	quiet $SUDO rmdir $MNT	# Leave no traces
    fi
    [ $# -eq 0 ] && return 0
    
    # Now the fun begins.  Make /etc/grub.d/[00_header|10_linux] happy
    LOCALIMG="$*"
    [ ! -f $LOCALIMG ] && LAST_KPARTX= && return 1
    quiet $SUDO mkdir -p $MNT
    quiet $SUDO kpartx -as $LOCALIMG
    [ $? -ne 0 ] && echo "kpartx of $LOCALIMG failed" >&2 && exit 1
    LAST_KPARTX=$LOCALIMG
    DEV=`losetup | awk -v mounted=$LAST_KPARTX '$0 ~ mounted {print $1}'`
    MOUNTDEV=/dev/mapper/`basename $DEV`p1
    quiet $SUDO mount $MOUNTDEV $MNT
    if [ $? -ne 0 ]; then
    	$SUDO kpartx -d $LAST_KPARTX
	LAST_KPARTX=
    	echo "mount of $LOCALIMG failed" >&2
	exit 1
    fi

    # bind mounts to make /etc/grub.d/XXX happy when they calls grub-probe
    OKREV=
    for BIND in $BINDFWD; do
	quiet $SUDO mkdir -p $MNT$BIND
	quiet $SUDO mount --bind $BIND $MNT$BIND
	if [ $? -ne 0 ]; then
	    echo "Bind mount of $BIND failed" >&2
	    [ "$OKREV" ] && for O in "$OKREV"; do quiet $SUDO umount $MNT$O; done
	    quiet $SUDO umount $MNT
	    return 1
	fi
	quiet echo Bound $BIND
	OKREV="$BIND $OKREV"	# reverse order is important during failures
    done
    return 0
}

###########################################################################
# Tri-state return value

function validate_template_image() {
    [ -f $TEMPLATE ] || return 1		# File not found
    mount_image $TEMPLATE || return 255		# aka return -1: corrupt
    test -d $MNT/home/l4tm			# see node_emulation.vmd
    RET=$?					# Incomplete
    mount_image
    return $RET
}

###########################################################################
# vmdebootstrap uses debootstrap which uses wget to retrieve packages.
# wget obeys (lower case) "http_proxy" but can be overridden by 
# or $HOME/.wgetrc or /etc/wgetrc.  Try to help; export http_proxy to
# avoid a reported issue in the VMD variable.

function expose_proxy() {
    if [ "$PROXY" ]; then	# override for this script
	[ "${PROXY:0:7}" != "http://" ] && PROXY="http://$PROXY"
	http_proxy=$PROXY
	https_proxy=`echo $PROXY | sed -e 's/http:/https:/'`
	export http_proxy https_proxy PROXY
	echo "http_proxy=$http_proxy (given by PROXY=)"
	return 0
    fi
    if [ "${http_proxy:-}" ]; then	# already there
	echo "http_proxy=$http_proxy (existing environment)"
	https_proxy=`echo $http_proxy | sed -e 's/http:/https:/'`
	export http_proxy https_proxy
	return 0
    fi
    for RC in $HOME/.wgetrc /etc/wgetrc; do
	TMP=`grep '^[[:space:]]*http_proxy' $RC 2>/dev/null | sed -e 's/[[:space:]]//g'`
	if [ "$TMP" ]; then
	    eval "$TMP"
	    export http_proxy
	    echo "http_proxy=$http_proxy (from $RC)"
	    return 0
	fi
    done
    echo "No proxy setting can be ascertained"
    return 0
}

###########################################################################
# Add the packages for L4TM (Linux for The Machine) via the secondary,
# partial repo of l4fame.  It was built with mini-dinstall so the
# syntax in sources.list.d looks a little funky.

function install_one() {
    echo Installing $1
    # quiet $SUDO chroot $MNT sh -c \
    # $SUDO chroot $MNT sh -c \
    quiet $SUDO chroot $MNT \
	"apt-get --allow-unauthenticated -y --force-yes install '$1'"
    return $?
}

###########################################################################
# Add the repo, pull the packages.  Yes multistrap might do this all at
# once but this script is evolutionary from a trusted base.  And then
# it still needs to have grub installed.

function transmogrify_l4fame() {
    mount_image $TEMPLATE || return 1
    sep "Extending template with L4FAME: updating sources..."
    L4FAME='http://downloads.linux.hpe.com/repo/l4fame'
    SOURCES="$MNT/etc/apt/sources.list.d/l4fame.list"
    APTCONF="$MNT/etc/apt/apt.conf.d/00l4fame.conf"
    echo "deb $L4FAME unstable/" | quiet $SUDO tee $SOURCES
    echo "deb-src $L4FAME unstable/" | quiet $SUDO tee -a $SOURCES

    # FIXME: did vmdebootstrap do this?
    if [ "$PROXY" ]; then
    	echo "Acquire::http::Proxy \"$PROXY\";" | quiet $SUDO tee $APTCONF
    fi

    # Without a key, you get error message on upgrade:
    # W: No sandbox user '_apt' on the system, can not drop privileges
    # N: Updating from such a repository can't be done securely, and is
    #    therefore disabled by default.
    # N: See apt-secure(8) manpage for repository creation and user
    #    configuration details.

    # Assumes wget came with vmdebootstrap.  bash is for the pipe.
    echo "Adding L4FAME GPG key..."
    quiet $SUDO chroot $MNT /bin/bash -c \
    	"'wget -O - https://db.debian.org/fetchkey.cgi?fingerprint=C383B778255613DFDB409D91DB221A6900000011 | apt-key add -'"
    [ $? -ne 0 ] && die "L4FAME GPG key installation failed"

    echo "Updating apt for L4FAME..."
    quiet $SUDO chroot $MNT apt-get update
    [ $? -ne 0 ] && die "Cannot refresh repo sources and preferences"
  
    # L4FAME does not come with a linux-image-amd64 metapackage to lock
    # its kernel down.  An apt-get update will probably blow this away.
    L4FAME_KERNEL="linux-image-4.8.0-l4fame+"	# Always use quotes.
    install_one "$L4FAME_KERNEL"
    [ $? -ne 0 ] && die "Cannot install L4FAME kernel"

    quiet $SUDO chroot $MNT apt-mark hold "$L4FAME_KERNEL"
    [ $? -ne 0 ] && echo "Cannot hold L4FAME kernel version $L4FAME_KERNEL"

    # Installing a kernel took info from /proc and /sys that set up
    # /etc/fstab, but it's from the host system.  Fix that, along with
    # other things.  Then finish off L4FAME.
    
    common_config_files

    install_one l4fame-node
    RET=$?

    mount_image

    return $RET 
}

###########################################################################
# This takes about six minutes if the mirror is unproxied on a LAN.  YMMV.

function manifest_template_image() {
    sep Creating VM system image $TEMPLATE from $MIRROR

    validate_template_image
    RET=$?
    [ $RET -eq 255 ] && quiet $SUDO rm -f $TEMPLATE && RET=0
    if [ $RET -eq 0 ]; then
    	yesno "Re-use existing $TEMPLATE"
	[ $? -eq 0 ] && return 0
    fi

    CFG=$PROJECT.vmd	# local

    VMD="$SUDO vmdebootstrap --no-default-configs --config=$CFG"

    # Does this vintage of vmdeboostrap eat "variant" or "debootstrapopts"?

    $VMD --dump-config | grep -q '^variant ='
    if [ $? -eq 0 ]; then
    	VAROPT='--variant=buildd'
    else
    	VAROPT='--debootstrapopts=variant=buildd'
    fi

    # vmdebootstrap calls debootstrap which makes a loopback mount for
    # the image under construction, like /dev/mapper/loop0p1.  It should
    # be possible to construct a status bar based on df of that mount.
    # NOTE: killing the script here may leave a dangling mount that
    # interferes with subsequent runs, but doesn't complain properly.
    # Later versions of vmdebootstrap don't take both --image and --tarball.

    $VMD $VAROPT --log=$LOG --image=$TEMPLATE \
    	--mirror=$MIRROR --owner=$SUDO_USER
    RET=$?
    quiet $SUDO chown $SUDO_USER "$ARTDIR/${HOSTUSERBASE}.*" 	# --owner bug
    if [ $RET -ne 0 -o ! -f $TEMPLATE ]; then
	BAD=`mount | grep '/dev/loop[[:digit:]]+p[[:digit:]]+'`
	[ $BAD ] && echo "mount of $BAD may be a problem" | tee -a $LOG
    	die "Build of $TEMPLATE failed"
    fi

    validate_template_image || die "Validation of fresh $TEMPLATE failed"

    transmogrify_l4fame || die "Addition of L4FAME repo failed"

    return 0
}

###########################################################################
# Helper for cloning into current image at $MNT

function common_config_files() {
    OCTETS123=192.168.42	# see fabric_emul.net.xml
    TORMS=$OCTETS123.254

    # One-liners

    # $SUDO cp hello_fabric.c $MNT/home/l4tm

    # Yes, the word "NEWHOST", which will be sedited later
    echo NEWHOST | quiet $SUDO tee $MNT/etc/hostname
    
    echo "http_proxy=$PROXY" | quiet $SUDO tee -a $MNT/etc/environment

    #------------------------------------------------------------------
    ETCHOSTS=$MNT/etc/hosts

    $SUDO tee $ETCHOSTS >/dev/null << EOHOSTS
127.0.0.1	localhost
127.1.0.1	NEWHOST

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$TORMS	torms vmhost `hostname`

EOHOSTS

    for I in `seq 1 40`; do
    	echo $OCTETS123.$I "${HOSTUSERBASE}$I" | \
		quiet $SUDO tee -a $ETCHOSTS
    done

    #------------------------------------------------------------------
    RESOLVdotCONF=$MNT/etc/resolv.conf

    echo "nameserver	$TORMS" | quiet $SUDO tee $RESOLVdotCONF

    #------------------------------------------------------------------
    FSTAB=$MNT/etc/fstab

    quiet $SUDO tee $FSTAB << EOFSTAB
proc		 /proc	proc	defaults	0 0 
/dev/sda1	/	ext4	defaults	0 0
EOFSTAB

    return 0
}

###########################################################################
# Copy, emit, convert: the 8G raw disk will drop to 800M qcow2.

function clone_VMs()
{
    sep Generating file system images for $NODES virtual machines
    for N in `seq $NODES`; do
    	NEWHOST=${HOSTUSERBASE}`printf "%02d" $N`
    	NEWIMG="$ARTDIR/$NEWHOST.img"
	QCOW2="$ARTDIR/$NEWHOST.qcow2"
	echo "Customize $NEWHOST..."
	quiet cp $TEMPLATE $NEWIMG

	# Fixup files
	mount_image $NEWIMG || die "Cannot mount $NEWIMG"
	for F in etc/hostname etc/hosts; do
		TARGET=$MNT/$F
		quiet $SUDO sed -ie "s/NEWHOST/$NEWHOST/" $TARGET
	done
	mount_image

	echo Converting $NEWIMG into $QCOW2
	quiet qemu-img convert -f raw -O qcow2 $NEWIMG $QCOW2
	quiet rm -f $NEWIMG
    done
    return 0
}

###########################################################################
# When in doubt, "qemu-system-x86_64 -device ?" or "-device virtio-net,?"

function emit_invocations() {
    DOIT=$ARTDIR/$PROJECT.bash
    sep "\nVM invocation script is $DOIT"

    cat >$DOIT <<EODOIT
#!/bin/bash

# Invoke VMs created by `basename $0`

# SUDO="sudo -E"	# Uncomment this if your system needs it

QEMU="\$SUDO qemu-system-x86_64 -enable-kvm"

[ -z "\$DISPLAY" ] && NODISPLAY="-display none"

EODOIT

    exec 3>&1		# Save stdout before...
    exec >>$DOIT	# ...hijacking it
    for N in `seq $NODES`; do
	D2=`printf "%02d" $N`
	NODE=$HOSTUSERBASE$D2
	# This pattern is recognized by tm-lfs as the implicit node number
	MAC="$HPEOUI:${D2}:${D2}:${D2}"
	echo "nohup \$QEMU -name $NODE \\"
	echo "	-netdev bridge,id=$NETWORK,br=$NETWORK,helper=$QBH \\"
	echo "	-device virtio-net,mac=$MAC,netdev=$NETWORK \\"
        echo "  --object memory-backend-file,size=$FAMSIZE,mem-path=$FAM,id=FAM,share=on \\"
        echo "  -device ivshmem-plain,memdev=FAM \\"
        echo "  -vnc :$N \\"
	echo "	\$NODISPLAY $ARTDIR/$NODE.qcow2 &"
	echo
    done
    exec 1>&3		# Restore stdout
    exec 3>&-
    chmod +x $DOIT
    return 0
}

###########################################################################
# MAIN

[ $# -ne 1 -o "${1:0:1}" = '-' ] && die "usage: `basename $0` [ -h ] VMcount"
typeset -ir NODES=$1	# will evaluate to zero if non-integer

set -u

[ "$NODES" -lt 1 -o "$NODES" -gt 40 ] && die "'$1' VMs is not in range 1-40"

trap "rm -f debootstrap.log; exit 0" TERM QUIT INT HUP EXIT # always empty

verify_host_environment

libvirt_bridge

expose_proxy

manifest_template_image

clone_VMs

emit_invocations

exit 0
