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
# Note: FAME_OUTDIR was originally TMPDIR, but that variable is suppressed
# by glibc on setuid programs which breaks under certain uses of sudo.

FAME_OUTDIR=${FAME_OUTDIR:-/tmp}
export FAME_OUTDIR=`dirname "$FAME_OUTDIR/xxx"`	# chomps a trailing slash

export FAME_VCPUS=${FAME_VCPUS:-2}		# No idiot checks yet

export FAME_VDRAM=${FAME_VDRAM:-786432}

export FAME_FAM=${FAME_FAM:-}			# blank will throw an erro

export FAME_MIRROR=${FAME_MIRROR:-http://ftp.us.debian.org/debian}

export FAME_PROXY=${FAME_PROXY:-$http_proxy}
http_proxy=${http_proxy:-}			# Yes, after FAME_PROXY

export FAME_VERBOSE=${FAME_VERBOSE:-}	# Default: mostly quiet; "yes" for more

# export FAME_L4FAME=${FAME_L4FAME:-http://l4fame.s3-website.us-east-2.amazonaws.com/}
export FAME_L4FAME=${FAME_L4FAME:-http://downloads.linux.hpe.com/repo/l4fame/Debian}

# A generic kernel metapackage is not created.  As we don't plan to update
# the kernel much, it's reasonably safe to hardcode this.  Version keeps
# shell and apt regex from blowing up on the '+' and trying the debug package.
# Experts only.
export FAME_KERNEL=${FAME_KERNEL:-"linux-image-4.14.0-l4fame+"}

###########################################################################
# Hardcoded to match content in external config files.  If any of these
# is zero length you will probably trash your host OS.  Bullets, gun, feet.

typeset -r HOSTUSERBASE=node
typeset -r PROJECT=${HOSTUSERBASE}_emulation
typeset -r LOG=$FAME_OUTDIR/$PROJECT.log
typeset -r NETWORK=${HOSTUSERBASE}_emul		# libvirt name length limits
typeset -r HPEOUI="48:50:42"
typeset -r TEMPLATEIMG=$FAME_OUTDIR/${HOSTUSERBASE}_template.img
typeset -r TARBALL=$FAME_OUTDIR/${HOSTUSERBASE}_template.tar
typeset -r OCTETS123=192.168.42			# see fabric_emul.net.xml
typeset -r TORMSIP=$OCTETS123.254

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
    [ "$FAME_VERBOSE" ] && env | sort >> $LOG
    echo -e "\n$LOG may have more details" >&2
    exit 1
}

function quiet() {
    if [ "$FAME_VERBOSE" ]; then
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
# Ass-u-me coreutils is installed.  Can't use die() until certain things
# check out.

[ `id -u` -ne 0 ] && SUDO="sudo -E" || SUDO=

function verify_host_environment() {
    sep Verifying host environment

    [ ! -d "$FAME_OUTDIR" ] && echo "$FAME_OUTDIR does not exist" >&2 && exit 1
    [ ! -w "$FAME_OUTDIR" ] && echo "$FAME_OUTDIR is not writeable" >&2 && exit 1

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

    # Another user submitted errata which may include
    # bison dh-autoreconf flex gtk2-dev libglib2.0-dev livbirt-bin zlib1g-dev
    [ -x /bin/which -o -x /usr/bin/which ] || die "Missing command 'which'"
    NEED="awk brctl grep libvirtd losetup qemu-img qemu-system-x86_64 virsh vmdebootstrap"
    [ "$SUDO" ] && NEED="$NEED sudo"
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

    # Got RAM/DRAM for the CPU?  Earlier QEMU had trouble booting this
    # environment in less than this space, could have been page tables
    # for larger IVSHMEM.  FIXME: force KiB values, verify against FAM_SIZE.
    [ $FAME_VDRAM -lt 786432 ] && die "FAME_VDRAM=$FAME_VDRAM KiB is too small"
    let TMP=${FAME_VDRAM}*${NODES}
    set -- `head -1 /proc/meminfo`
    [ $2 -lt $TMP ] && die "Insufficient real RAM for $NODES nodes of $FAME_VDRAM KiB each"

    # Got FAM?  And is it sized correctly?
    [ -z "$FAME_FAM" ] && die "FAME_FAM variable must be specified"
    [ ! -f "$FAME_FAM" ] && die "$FAME_FAM not found"
    T=`stat -c %s "$FAME_FAM"`
    # Shell boolean values are inverse of Python
    python3 -c "import math; e=math.log2($T); exit(not(e == int(e)))"
    [ $? -ne 0 ] && die "$FAME_FAM size $T is not a power of 2"

    # QEMU limit is a function of the (pass-through) host CPU and available
    # memory (about half of true free RAM plus a fudge factor?).  Max size
    # is an ADVISORY because it may work.  This is coupled with a new
    # check in lfs_shadow.py; if the value is too big, IVSHMEM is bad
    # from the guest point of view.
    let TMP=$T/1024/1024/1024
    export FAME_SIZE=${TMP}G
    quiet echo "$FAME_FAM = $FAME_SIZE"
    [ $TMP -lt 1 ] && die "$FAME_FAM size $T is less than 1G"
    [ $TMP -gt 512 ] && echo "$FAME_FAM size $TMP is greater than 512G"

    # This needs to become smarter, looking for stale kpartx devices
    LOOPS=`$SUDO losetup -al | grep devicemapper | grep -v docker | wc -l`
    [ $LOOPS -gt 0 ] && die \
    	'losetup -al shows active loopback mounts, please clear them'

    # verified working QEMU versions, checked only to "three digits"
    VERIFIED_QEMU_VERSIONS="2.6.0 2.8.0 2.8.1"
    set -- `qemu-system-x86_64 -version`
    # Use regex to check the current version against VERIFIED_QEMU_VERSIONS.
    # See man page for bash, 3.2.4.2 Conditional Constructs.  No quotes.
    [[ $VERIFIED_QEMU_VERSIONS =~ ${4:0:5} ]] || \
    	die "qemu is not version" ${VERIFIED_QEMU_VERSIONS[*]}
    verify_QBH

    # Space for 2 raw image files, the tarball, all qcows, and slop
    [ ! -d "$FAME_OUTDIR" ] && die "$FAME_OUTDIR is not a directory"
    let GNEEDED=16+1+$NODES+1
    let KNEEDED=1000000*$GNEEDED
    TMPFREE=`df "$FAME_OUTDIR" | awk '/^\// {print $4}'`
    [ $TMPFREE -lt $KNEEDED ] && die "$FAME_OUTDIR has less than $GNEEDED G free"

    echo_environment EXPORT > $FAME_OUTDIR/env.sh	# For next time

    return 0
}

###########################################################################
# libvirt / virsh / qemu / kvm stuff

function libvirt_bridge() {
    sep Configure libvirt network bridge \"$NETWORK\"

    NETXML=templates/network.xml
    [ ! -f $NETXML ] && die "Missing local file $NETXML"

    # Some installations set up LIBVIRT_DEFAULT, but the virsh man page
    # says LIBVIRT_DEFAULT_URI.  Get the deprecated version, too..
    export LIBVIRT_DEFAULT="${LIBVIRT_DEFAULT:-qemu:///system}"
    export LIBVIRT_DEFAULT_URI=$LIBVIRT_DEFAULT
    export LIBVIRT_DEFAULT_CONNECT_URI=$LIBVIRT_DEFAULT

    export VIRSH_DEBUG=0
    export VIRSH_LOG_FILE=$LOG
    VIRSH="$SUDO virsh"
    quiet $VIRSH connect
    [ $? -ne 0 ] && die "'virsh connect' failed, is libvirtd running?"
    $VIRSH net-list --all | grep -q '^ Name.*State.*Autostart.*Persistent$'
    [ $? -ne 0 ] && die "virsh net-list command is not working as expected"

    for CMD in net-destroy net-undefine; do
	quiet $VIRSH $CMD $NETWORK
	sleep 1
    done

    # virsh will define a net with a loooong name, but fail on starting it.
    quiet $VIRSH net-define $NETXML
    [ $? -ne 0 ] && die "Cannot define the network $NETWORK:\n`cat $NETXML`"

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
#	image $TEMPLATEIMG (/tmp/node_template.img).  Since that file doesn't
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
typeset -r BINDFWD="/proc /sys /run /dev /dev/pts"
typeset -r BINDREV="`echo $BINDFWD | tr ' ' '\n' | tac`"
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

    # Do not die() from in here or you might get infinite recursion.
    [ $? -ne 0 ] && echo "kpartx of $LOCALIMG failed" >&2 && exit 1
    LAST_KPARTX=$LOCALIMG
    DEV=`losetup | awk -v mounted=$LAST_KPARTX '$0 ~ mounted {print $1}'`
    MOUNTDEV=/dev/mapper/`basename $DEV`p1
    quiet $SUDO mount $MOUNTDEV $MNT
    if [ $? -ne 0 ]; then
    	$SUDO kpartx -d $LAST_KPARTX
	LAST_KPARTX=
    	echo "mount of $LOCALIMG failed" >&2
	exit 1	# die() might cause infinite recursion
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
    [ -f $TEMPLATEIMG ] || return 1		# File not found
    mount_image $TEMPLATEIMG || return 255	# aka return -1: corrupt
    test -d $MNT/home/l4tm			# see vmd.xxx files
    RET=$?					# Incomplete
    mount_image
    return $RET
}

###########################################################################
# vmdebootstrap uses debootstrap which uses wget to retrieve packages.
# wget obeys (lower case) "http_proxy" but can be overridden by
# $HOME/.wgetrc or /etc/wgetrc.  Try to help; export http_proxy to
# avoid a reported issue in the VMD variable.

function expose_proxy() {
    if [ "$FAME_PROXY" ]; then	# may have come from http_proxy originally
    	if [ "${http_proxy:-}" ]; then
	    echo "http_proxy=$http_proxy (existing environment)"
	else
	    echo "http_proxy=$FAME_PROXY (from FAME_PROXY)"
	fi
	[ "${FAME_PROXY:0:7}" != "http://" ] && FAME_PROXY="http://$FAME_PROXY"
	http_proxy=$FAME_PROXY
	https_proxy=`echo $FAME_PROXY | sed -e 's/http:/https:/'`
	export http_proxy https_proxy FAME_PROXY
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
# Add a package, most uses are fulfilled from the second FAME_L4FAME.
# Remember APT::Get::AllowUnauthenticated was set earlier.

function install_one() {
    echo Installing $1
    quiet $SUDO chroot $MNT apt-cache show $1	# "search" is fuzzy match
    RET=$?
    [ $RET -ne 0 ] && echo "No candidate matches $1" >&2 && return $RET

    # Here's a day I'll never get back :-)  DEBIAN_FRONTEND env var is the
    # easiest way to get this per-package (debconf-get/set would be needed).
    # "man bash" for -c usage, it's not what you think.  The outer double
    # quotes send a single arg to quiet() while allowing evaluation of $1.
    # The inner single quotes are preserved across the chroot to create a
    # single arg for "bash -c".
    quiet $SUDO chroot $MNT /bin/bash -c \
	"'DEBIAN_FRONTEND=noninteractive; apt-get -y --force-yes install $1'"
    RET=$?
    [ $RET -ne 0 ] && echo "Install failed" >&2 && return $RET

    quiet $SUDO chroot $MNT dpkg -l $1	# Paranoia
    RET=$?
    [ $RET -ne 0 ] && echo "dpkg -l after install failed" >&2 && return $RET
    return 0
}

###########################################################################
# Add the repo, pull the packages.  Yes multistrap might do this all at
# once but this script is evolutionary from a trusted base.  And then
# it still needs to have grub installed.

function transmogrify_l4fame() {
    mount_image $TEMPLATEIMG || return 1
    sep "Extending template with L4FAME: updating sources..."
    APTCONF="$MNT/etc/apt/apt.conf.d/00FAME.conf"
    SOURCES="$MNT/etc/apt/sources.list.d/l4fame.list"

    # Make allowances for container-based self-hosted repo
    echo "APT::Get::AllowUnauthenticated \"True\";" | quiet $SUDO tee $APTCONF
    echo "Acquire::http::Proxy::$TORMSIP \"DIRECT\";" | quiet $SUDO tee -a $APTCONF

    # vmdebootstrap does not take care of this.
    if [ "$FAME_PROXY" ]; then
    	echo "Acquire::http::Proxy \"$FAME_PROXY\";" | quiet $SUDO tee -a $APTCONF
    fi

    #------------------------------------------------------------------
    # wget: certain distros (ex: Debian stretch) install a symlink that
    # may be unresolved in a bind mount.  Hardcode a simple file so the
    # wget will work.  In the chroot, this will resolve directly against
    # the dnsmasq assigned to the virtual bridge, which will fall over
    # to the host resolver and do the right thing.

    RESOLVdotCONF=$MNT/etc/resolv.conf
    quiet $SUDO unlink $RESOLVdotCONF
    echo "nameserver	$TORMSIP" | quiet $SUDO tee $RESOLVdotCONF

    # A repo container on this host should be expressed as localhost.

    if [ "$FAME_L4FAME" ]; then		# Assume full repo, not minideb
	if [[ $FAME_L4FAME =~ localhost ]]; then
	    USED_L4FAME=`echo $FAME_L4FAME | sed -e "s/localhost/$TORMSIP/"`
	else
	    USED_L4FAME=$FAME_L4FAME
	fi
    	echo "deb $USED_L4FAME testing main" | quiet $SUDO tee $SOURCES
    else
    	FAME_L4FAME='http://downloads.linux.hpe.com/repo/l4fame'
    	echo "deb $FAME_L4FAME unstable/" | quiet $SUDO tee $SOURCES
    	echo "deb-src $FAME_L4FAME unstable/" | quiet $SUDO tee -a $SOURCES

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
    fi

    echo "Contacting $FAME_L4FAME..."
    quiet wget -O /dev/null $FAME_L4FAME > /dev/null 2>&1
    [ $? -ne 0 ] && die "Cannot reach $FAME_L4FAME"

    echo "Updating apt from $FAME_L4FAME..."
    quiet $SUDO chroot $MNT apt-get --allow-unauthenticated update
    [ $? -ne 0 ] && die "Cannot refresh repo sources and preferences"

    install_one "$FAME_KERNEL"	# Always use quotes.
    [ $? -ne 0 ] && die "Cannot install L4FAME kernel"

    quiet $SUDO chroot $MNT apt-mark hold "$FAME_KERNEL"
    [ $? -ne 0 ] && echo "Cannot hold L4FAME kernel version $FAME_KERNEL"

    # Installing a kernel took info from /proc and /sys that set up
    # /etc/fstab, but it's from the host system.  Fix that, along with
    # other things.  Then finish off L4FAME.

    common_config_files

    for E in l4fame-node; do
    	install_one $E
	RET=$?
	[ $RET -ne 0 ] &&  echo "$E failed" >&2 && break
    done

    mount_image

    return $RET
}

###########################################################################
# This takes about six minutes if the mirror is unproxied on a LAN.  YMMV.

function manifest_template_image() {
    sep Handle VM golden image $TEMPLATEIMG

    validate_template_image
    RET=$?
    [ $RET -eq 255 ] && quiet $SUDO rm -f $TEMPLATEIMG && RET=0
    if [ $RET -eq 0 ]; then
    	yesno "Re-use existing $TEMPLATEIMG"
	[ $? -eq 0 ] && echo "Keep existing $TEMPLATEIMG" && return 0
    fi
    echo Creating new $TEMPLATEIMG from $FAME_MIRROR

    # Different versions eat different arguments.  --dump-config used to be
    # an easy test but with later versions the arg list started getting
    # unwieldy.  Use multiple VMD files.  VERIFIED_XXX means it's truly been
    # tested at least once.  The lists are easier than numeric comparisons. 
    # Use regex to check the current version against different lists.

    VMDVER=`vmdebootstrap --version`
    declare -A VERIFIED
    # --variant
    VERIFIED['A']="0.2 0.5"	
    # --debootstrapopts, use-uefi, systemd-networkd, configure-apt, esp-size
    VERIFIED['B']="1.6"		

    SUFFIX=NO_SUCH_VMD
    for KEY in ${!VERIFIED[@]}; do
    	# See man page for bash, 3.2.4.2 Conditional Constructs.  No quotes.
    	[[ ${VERIFIED[$KEY]} =~ $VMDVER ]] && SUFFIX=$KEY && break
    done
    VMDCFG="templates/vmd_$SUFFIX"
    [ ! -f $VMDCFG ] && die "vmdebootstrap $VMDVER is not implemented"
    quiet echo Using $VMDCFG

    VMD="$SUDO vmdebootstrap --no-default-configs --config=$VMDCFG"

    # vmdebootstrap calls debootstrap which makes a loopback mount for
    # the image under construction, like /dev/mapper/loop0p1.  It should
    # be possible to construct a status bar based on df of that mount.
    # NOTE: killing the script here may leave a dangling mount that
    # interferes with subsequent runs, but doesn't complain properly.
    # Later versions of vmdebootstrap don't take both --image and --tarball.

    $VMD --log=$LOG --image=$TEMPLATEIMG \
    	--mirror=$FAME_MIRROR --owner=$SUDO_USER
    RET=$?
    quiet $SUDO chown $SUDO_USER "$FAME_OUTDIR/${HOSTUSERBASE}.*" 	# --owner bug
    if [ $RET -ne 0 -o ! -f $TEMPLATEIMG ]; then
	BAD=`mount | grep '/dev/loop[[:digit:]]+p[[:digit:]]+'`
	[ $BAD ] && echo "mount of $BAD may be a problem" | tee -a $LOG
    	die "Build of $TEMPLATEIMG failed"
    fi

    validate_template_image || die "Validation of fresh $TEMPLATEIMG failed"

    quiet $SUDO mv -f dpkg.list $FAME_OUTDIR	# "pklist" is hardcoded here

    transmogrify_l4fame || die "Addition of L4FAME repo failed"

    return 0
}

###########################################################################
# Helper for cloning into current image at $MNT

function common_config_files() {

    # One-liners

    # $SUDO cp hello_fabric.c $MNT/home/l4tm

    # Yes, the word "NEWHOST", which will be sedited later
    echo NEWHOST | quiet $SUDO tee $MNT/etc/hostname

    echo "http_proxy=$FAME_PROXY" | quiet $SUDO tee -a $MNT/etc/environment

    #------------------------------------------------------------------
    SUDOER=$MNT/etc/sudoers.d/l4tm_phraseless

    echo $SUDOER

    echo "l4tm	ALL=(ALL:ALL) NOPASSWD: ALL" | quiet $SUDO tee $SUDOER

    #------------------------------------------------------------------
    ETCHOSTS=$MNT/etc/hosts

    quiet $SUDO tee $ETCHOSTS << EOHOSTS
127.0.0.1	localhost
127.1.0.1	NEWHOST

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$TORMSIP	torms vmhost `hostname`

EOHOSTS

    # Not really needed with dnsmasq doing DNS but helps when nodes are down
    # as dnsmasq omits them.
    for I in `seq $NODES`; do
    	echo $OCTETS123.$I "${HOSTUSERBASE}$I" | \
		quiet $SUDO tee -a $ETCHOSTS
    done

    #------------------------------------------------------------------
    FSTAB=$MNT/etc/fstab

    # NFS mount of "defaults" breaks; journalctl -xe | grep srv shows why.
    # Google for "srv.mount nfs before network" and get to
    # https://wiki.archlinux.org/index.php/NFS#Mount_using_.2Fetc.2Ffstab_with_systemd
    # It mounts on first use, after waiting for networking, timeout 10 seconds
    # in case "torms" isn't exporting /srv
    # HOWEVER the automount is erratic, folks take it out, and Poettering 
    # just closed it.  Experimentation yielded this combo (no timeout)...

    quiet $SUDO tee $FSTAB << EOFSTAB
proc		/proc	proc	defaults	0 0
/dev/vda1	/	auto	defaults	0 0
torms:/srv	/srv	nfs	noauto,noatime,x-systemd.requires=network.target,x-systemd.automount 0 0
EOFSTAB

    return 0
}

###########################################################################
# Copy, emit, convert: the 8G raw disk will drop to 800M qcow2.

function clone_VMs()
{
    sep Generating file system images for $NODES virtual machines
    for N2 in `seq -f '%02.0f' $NODES`; do
    	NEWHOST=$HOSTUSERBASE$N2
	QCOW2="$FAME_OUTDIR/$NEWHOST.qcow2"
	if [ -f $QCOW2 ]; then
	    yesno "Re-use $QCOW2"
	    [ $? -eq 0 ] && echo "Keep existing $QCOW2" && continue
	fi
	$SUDO rm -f $QCOW2

	echo "Customize $NEWHOST..."
    	NEWIMG="$FAME_OUTDIR/$NEWHOST.img"
	quiet cp $TEMPLATEIMG $NEWIMG

	# Fixup files
	mount_image $NEWIMG || die "Cannot mount $NEWIMG"
	for F in etc/hostname etc/hosts; do
		TARGET=$MNT/$F
		quiet $SUDO sed -i -e "s/NEWHOST/$NEWHOST/" $TARGET
	done

	DOTSSH=$MNT/home/l4tm/.ssh
	quiet $SUDO mkdir -m 700 $DOTSSH
	quiet $SUDO cp templates/id_rsa.nophrase     $DOTSSH
	quiet $SUDO cp templates/id_rsa.nophrase.pub $DOTSSH/authorized_keys
	# The "l4tm" user in the chroot might be different from the host.

	# FIXME but this is a reasonable assumption on a fresh vmdebootstrap.
	quiet $SUDO chown -R 1000:1000 $DOTSSH
	quiet $SUDO chmod 400 $DOTSSH/id_rsa.nophrase
	quiet $SUDO tee $DOTSSH/config << EOSSHCONFIG
ConnectTimeout 5
StrictHostKeyChecking no

Host node*
	User l4tm
	IdentityFile ~/.ssh/id_rsa.nophrase
EOSSHCONFIG

    	quiet $SUDO chroot $MNT systemctl enable tm-lfs

	mount_image

	echo Converting $NEWIMG into $QCOW2
	quiet qemu-img convert -f raw -O qcow2 $NEWIMG $QCOW2
	quiet rm -f $NEWIMG
    done
    return 0
}

###########################################################################
# When in doubt, "qemu-system-x86_64 -device ?" or "-device virtio-net,?"

function emit_qemu_invocations_DEPRECATED() {
    DOIT=$FAME_OUTDIR/$PROJECT.bash
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
    for N2 in `seq -f '%02.0f' $NODES`; do
	NODE=$HOSTUSERBASE$N2
	# This pattern is recognized by tm-lfs as the implicit node number
	MAC="$HPEOUI:${N2}:${N2}:${N2}"
	echo "nohup \$QEMU -name $NODE \\"
	echo "	-netdev bridge,id=$NETWORK,br=$NETWORK,helper=$QBH \\"
	echo "	-device virtio-net,mac=$MAC,netdev=$NETWORK \\"
        echo "  --object memory-backend-file,size=$FAME_SIZE,mem-path=$FAME_FAM,id=FAM,share=on \\"
        echo "  -device ivshmem-plain,memdev=FAM \\"
        echo "  -vnc :$N \\"
	echo "	\$NODISPLAY $FAME_OUTDIR/$NODE.qcow2 &"
	echo
    done
    exec 1>&3		# Restore stdout
    exec 3>&-
    chmod +x $DOIT
    return 0
}

###########################################################################
# Create virt-manager files

function emit_libvirt_XML() {
    sep "\nvirsh/virt-manager files nodeXX.xml are in $FAME_OUTDIR"
    for N2 in `seq -f '%02.0f' $NODES`; do
	NODEXX=$HOSTUSERBASE$N2
	# This pattern is recognized by tm-lfs as the implicit node number
	MACADDRXX="$HPEOUI:${N2}:${N2}:${N2}"
	QCOWXX=$FAME_OUTDIR/$NODEXX.qcow2
	NODEXML=$FAME_OUTDIR/$NODEXX.xml

	grep -q 'model name.*AMD' /proc/cpuinfo
	[ $? -eq 0 ] && MODEL=amd || MODEL=intel
	SRCXML=templates/node.$MODEL.xml
	cp $SRCXML $NODEXML

	sed -i -e "s!NODEXX!$NODEXX!" $NODEXML
	sed -i -e "s!QCOWXX!$QCOWXX!" $NODEXML
	sed -i -e "s!MACADDRXX!$MACADDRXX!" $NODEXML
	sed -i -e "s!FAME_VDRAM!$FAME_VDRAM!" $NODEXML
	sed -i -e "s!FAME_VCPUS!$FAME_VCPUS!" $NODEXML
	sed -i -e "s!FAME_FAM!$FAME_FAM!" $NODEXML
	sed -i -e "s!FAME_SIZE!$FAME_SIZE!" $NODEXML
    done
    cp templates/node_virsh.sh $FAME_OUTDIR
    echo "Change directory to $FAME_OUTDIR and run node_virsh.sh"
    return 0
}

###########################################################################

function echo_environment() {
    FAME_FAM=${FAME_FAM:-"NEEDS TO BE SET!"}
    echo "http_proxy=$http_proxy"
    _VARS=`env | grep FAME_ | sort`
    for V in $_VARS; do echo $V; done
    if [ $# -gt 0 ]; then
	_VARS=`cut -d= -f1 <<< $_VARS`
	for V in $_VARS; do echo "export $V"; done
    fi
}

###########################################################################
# MAIN - do a few things before set -u

if [ $# -ne 1 -o "${1:0:1}" = '-' ]; then
	echo "Environment:"
	echo_environment
	echo -e "\nusage: `basename $0` [ -h|? ] [ VMcount ]"
	exit 0
fi
typeset -ir NODES=$1	# will evaluate to zero if non-integer

set -u

[ "$NODES" -lt 1 -o "$NODES" -gt 40 ] && die "VM count is not in range 1-40"

trap "rm -f debootstrap.log; exit 0" TERM QUIT INT HUP EXIT # always empty

verify_host_environment

libvirt_bridge

expose_proxy

manifest_template_image

clone_VMs

# emit_qemu_invocations

emit_libvirt_XML

exit 0
