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
# Hardcoded to match content in external config files

HOSTUSERBASE=fabric
PROJECT=${HOSTUSERBASE}_emulation
LOG=$ARTDIR/$PROJECT.log
NETWORK=${HOSTUSERBASE}_emul	# libvirt: occasional name length limits
OUI="48:50:45"			# man ascii
TEMPLATE=$ARTDIR/${HOSTUSERBASE}_template.img
TARBALL=$ARTDIR/${HOSTUSERBASE}_template.tar

###########################################################################
# Helpers

function sep() {
    SEP=". . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . ."
    echo -e "$SEP\n$*\n"
    return 0
}

# Early calls (before SUDO is set up) may not make it into $LOG
function die() {
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
    NEED="awk brctl grep qemu-img sudo virsh vmdebootstrap"
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

MNT=/mnt/$PROJECT
BINDFWD="/proc /sys /run /dev /dev/pts"
BINDREV="`echo $BINDFWD | tr ' ' '\n' | tac`"

function mount_image() {
    for BIND in $BINDREV; do quiet $SUDO umount $MNT$BIND; done
    quiet $SUDO umount $MNT
    if [ $# -eq 0 ]; then
	quiet $SUDO rmdir $MNT	# Leave no traces
	return 0
    fi
    LOCALIMG="$*"
    [ ! -f $LOCALIMG ] && return 1
    quiet $SUDO mkdir -p $MNT
    quiet $SUDO mount -oloop,offset=1M "$LOCALIMG" $MNT
    [  $? -ne 0 ] && echo "Mount of $LOCALIMG failed" >&2 && return 1

    # bind mounts for grub-probe from update-initramfs, etc
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
    [ -f $TEMPLATE ] || return 1
    mount_image $TEMPLATE || return 255		# aka return -1
    test -d $MNT/home/$HOSTUSERBASE
    RET=$?
    mount_image
    return $RET
}


###########################################################################
# vmdebootstrap uses debootstrap which uses wget to retrieve packages.
# wget obeys (lower case) "http_proxy" but can be overridden by 
# or $HOME/.wgetrc or /etc/wgetrc.  Try to help; export http_proxy to
# avoid a reported issue in the VMD variable.

function expose_proxy() {
    for RC in $HOME/.wgetrc /etc/wgetrc; do
	TMP=`grep '^[[:space:]]*http_proxy' $RC 2>/dev/null | sed 's/[[:space:]]//g'`
	if [ "$TMP" ]; then
	    eval "$TMP"
	    export http_proxy
	    echo "http_proxy=$http_proxy (from $RC)"
	    return 0
	fi
    done
    if [ "$PROXY" ]; then	# override for this script
	http_proxy=$PROXY
	export http_proxy
	echo "http_proxy=$http_proxy (from override by PROXY=)"
	return 0
    fi
    if [ "${http_proxy:-}" ]; then	# already there
	echo "http_proxy=$http_proxy (existing environment)"
	return 0
    fi
    echo "No proxy setting can be ascertained"
    return 0
}

###########################################################################
# Add the packages for L4TM (Linux for The Machine) via the secondary,
# partial repo of l4fame.  It was built with mini-dinstall so the
# syntax in source.list looks a little funky.

function transmogrify_l4fame() {
    sep "Extending template with L4FAME: updating sources..."
    mount_image $TEMPLATE || return 1
    L4FAME='http://downloads.linux.hpe.com/repo/l4fame'
    SOURCES="$MNT/etc/apt/sources.list.d/l4fame.list"
    APTCONF="$MNT/etc/apt/apt.conf.d/00l4fame.conf"
    echo "deb $L4FAME unstable/" | $SUDO tee $SOURCES 2>/dev/null
    echo "deb-src $L4FAME unstable/" | $SUDO tee -a $SOURCES 2>/dev/null
    if [ "$PROXY" ]; then
    	echo "Acquire::http::Proxy \"$PROXY\";" | sudo tee $APTCONF >/dev/null
    fi

    # Without a key, you get error message on upgrade:
    # W: No sandbox user '_apt' on the system, can not drop privileges
    # N: Updating from such a repository can't be done securely, and is
    #    therefore disabled by default.
    # N: See apt-secure(8) manpage for repository creation and user
    #    configuration details.

    echo "Adding packages..."	# Assumes wget came with vmdebootstrap

    quiet $SUDO chroot $MNT sh -c \
    	'wget -O - https://db.debian.org/fetchkey.cgi?fingerprint=C383B778255613DFDB409D91DB221A6900000011 | apt-key add -'
    [ $? -ne 0 ] && die "L4FAME GPG key installation failed"

    ERRORS=0
    for VERB in update ; do
    	quiet $SUDO chroot $MNT /bin/sh -c "apt $VERB -y --force-yes"
    	let ERRORS=${ERRORS}+$?
    done
    [ $ERRORS -ne 0 ] && die "Cannot refresh repo sources"

    for P in 'linux-image-4.8.0-l4fame+' 'l4fame-node'; do
    	quiet $SUDO chroot $MNT sh -c \
	    "DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes install '$P'"
    	let ERRORS=${ERRORS}+$?
    done
    mount_image
    return $ERRORS
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

    expose_proxy

    CFG=$PROJECT.vmd	# local

    VMD="$SUDO vmdebootstrap --no-default-configs --config=$CFG"

    # Does this vintage of vmdeboostrap eat "variant" or "debootstrapopts"?

    $VMD --dump-config | grep -q '^variant ='
    if [ $? -eq 0 ]; then
    	VAROPT='--variant=buildd'
    else
    	VAROPT='--debootstrapopts=variant=buildd'	# per KP
    fi

    # vmdebootstrap calls debootstrap which makes a loopback mount for
    # the image under construction, like /dev/mapper/loop0p1/.  It should
    # be possible to construct a status bar based on df of that mount.
    # NOTE: killing the script here may leave a dangling mount that
    # interferes with subsequent runs, but doesn't complain properly.
    # Later versions of vmdebootstrap don't take both --image and --tarball.

    quiet $VMD $VAROPT --log=$LOG --image=$TEMPLATE \
    	--mirror=$MIRROR --owner=$SUDO_USER
    RET=$?
    quiet $SUDO chown $SUDO_USER "/$ARTDIR/${HOSTUSERBASE}.*" 	# --owner bug
    if [ $RET -ne 0 ]; then
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

function emit_files() {
    NEWHOST=$1

    # One-liners

    $SUDO cp hello_${HOSTUSERBASE}.c $MNT/home/$HOSTUSERBASE

    echo $NEWHOST | $SUDO tee $MNT/etc/hostname >/dev/null
    
    echo "http_proxy=$PROXY" | $SUDO tee -a $MNT/etc/hostname >/dev/null

    echo 'nameserver	192.168.42.254' | \
    	$SUDO tee $MNT/etc/resolv.conf >/dev/null

    #------------------------------------------------------------------

    $SUDO tee $MNT/etc/hosts >/dev/null << EOHOSTS
127.0.0.1	localhost
127.1.0.1	$NEWHOST

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

192.168.42.254	torms vmhost `hostname`

EOHOSTS

    for I in `seq 1 40`; do
    	echo 192.168.42.$I "${HOSTUSERBASE}$I" | \
		sudo tee $MNT/etc/hosts >/dev/null
    done

    return 0
}

###########################################################################
# Copy, emit, convert: the 8G raw disk will drop to 800M qcow2.

function clone_VMs()
{
    sep Generating file system images for $NODES virtual machines
    for N in `seq $NODES`; do
    	NEWHOST=${HOSTUSERBASE}`printf "%d" $N`
    	NEWIMG="$ARTDIR/$NEWHOST.img"
	QCOW2="$ARTDIR/$NEWHOST.qcow2"
	echo "Customize $NEWHOST..."
	quiet cp $TEMPLATE $NEWIMG

	mount_image $NEWIMG || die "Cannot mount $NEWIMG"
	emit_files $NEWHOST
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
# `date`

# SUDO="sudo -E"	# Uncomment this if your system needs it

QEMU="\$SUDO qemu-system-x86_64 -enable-kvm"

[ -z "\$DISPLAY" ] && NODISPLAY="-display none"

EODOIT

    exec 3>&1		# Save stdout before...
    exec >>$DOIT	# ...hijacking it
    for N in `seq $NODES`; do
	NODE=$HOSTUSERBASE$N
	D2=`printf "%02d" $N`
	# This pattern is recognized by tm-lfs as the implicit node number
	MAC="$OUI:${D2}:${D2}:${D2}"
	echo "nohup \$QEMU -name $NODE \\"
	echo "	-netdev bridge,id=$NETWORK,br=$NETWORK,helper=$QBH \\"
	echo "	-device virtio-net,mac=$MAC,netdev=$NETWORK \\"
        echo "  --object memory-backend-file,size=$FAMSIZE,mem-path=$FAM,id=FAM,share=on \\"
        echo "  -device ivshmem-plain,memdev=FAM \\"
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

manifest_template_image

clone_VMs

emit_invocations

exit 0
