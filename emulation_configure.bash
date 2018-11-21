#!/bin/bash

# Copyright 2015-2018 Hewlett Packard Enterprise Development LP

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
# See https://github.com/FabricAttachedMemory for more details.

# Set these in your environment to override the following defaults.
# Note: FAME_DIR was originally TMPDIR, but that variable is suppressed
# by glibc on setuid programs which breaks under certain uses of sudo.

# Blanks for FAME_DIR and FAME_FAM will throw an error later.
FAME_DIR=${FAME_DIR:-}
[ "$FAME_DIR" ] && FAME_DIR=`dirname "$FAME_DIR/xxx"`	# chomp trailing slash
export FAME_DIR

export FAME_FAM=${FAME_FAM:-}

export FAME_USER=${FAME_USER:-l4mdc}

export FAME_VFS_GBYTES=${FAME_VFS_GBYTES:-6}	# Max size of a node FS

export FAME_VCPUS=${FAME_VCPUS:-2}		# No idiot checks yet

export FAME_VDRAM=${FAME_VDRAM:-786432}

export FAME_MIRROR=${FAME_MIRROR:-http://ftp.us.debian.org/debian}

export FAME_PROXY=${FAME_PROXY:-$http_proxy}
export http_proxy=${http_proxy:-}		# Yes, after FAME_PROXY
export https_proxy=${https_proxy:-}

export FAME_VERBOSE=${FAME_VERBOSE:-}	# Default: mostly quiet; "yes" for more

export FAME_L4FAME=${FAME_L4FAME:-https://downloads.linux.hpe.com/repo/l4fame/Debian}

export FAME_HOSTBASE=${FAME_HOSTBASE:-node}

export FAME_OCTETS123=${FAME_OCTETS123:-192.168.42}

# A generic kernel metapackage is not created.  As we don't plan to update
# the kernel much, it's reasonably safe to hardcode this regex.  The
# only other option is to scan the repo, ugh.
export FAME_KERNEL=${FAME_KERNEL:-"linux-image-4.14.0-fame"}

# Set to non-null (yes|true|1|whatever) to emit FAME-Z configuration.
# It gets reset early to a good location for the AF_UNIX socket.
export FAME_FAMEZ=${FAME_FAMEZ:-}

###########################################################################
# Hardcoded to match content in external config files.  If any of these
# is zero length you will probably trash your host OS.  Bullets, gun, feet.

typeset -r PROJECT=${FAME_HOSTBASE}_emulation
typeset -r NETWORK=br_${FAME_HOSTBASE}		# libvirt has name length limits
typeset -r HPEOUI="48:50:42"
typeset -r TORMSIP=$FAME_OCTETS123.254
typeset -r DOCKER_DIR=/fame_dir			# See Makefile and Docker.md

# Can be reset under Docker so no typeset -r
LOG=$FAME_DIR/${FAME_HOSTBASE}_log		# Yes underscore
TEMPLATEIMG=$FAME_DIR/${FAME_HOSTBASE}_template.img

export DEBIAN_FRONTEND=noninteractive	# preserved by chroot
export DEBCONF_NONINTERACTIVE_SEEN=true
export LC_ALL=C LANGUAGE=C LANG=C

###########################################################################
# Helpers

SEP_SECTION=0

function sep() {
    # Always log it and always see it to have something to grep the log.
    let SEP_SECTION+=1
    SEP="Section $SEP_SECTION -----------------------------------------------"
    echo -e "$SEP\n$*\n" | tee -a $LOG
}

function log() {
	[ "$FAME_VERBOSE" ] && echo -e "$*"
	echo -e "$*" >> "$LOG"
}

function warn() {
    echo -e "\nWARNING: $*\n" >&2
    echo -e "\nWARNING: $*\n" >> $LOG
}

# Early calls (before SUDO is set up) may not make it into $LOG
function die() {
    mount_image		# release anything that may be mounted
    echo -e "\nERROR: $*\n" >&2
    echo -e "\n$0 failed:\n$*\n" >> $LOG
    [ "$FAME_VERBOSE" ] && env | sort >> $LOG
    echo -e "\n$LOG may have more details" >&2
    exit 1
}

function quiet() {
    local RET
    log "$*"
    if [ "$FAME_VERBOSE" ]; then
    	eval $* 2>&1 | tee -a $LOG
	RET=${PIPESTATUS[-1]}	# cuz tee always works
    else
    	eval $* >> $LOG 2>&1 
	RET=$?
    fi
    return $RET
}

# Use this for dependable functions with local-only dependencies for success,
# ie, file system ops.  Don't use it with "external" actions like apt-get.
# It's like a decorator for quiet().

function debug() {
    local SAVED_VERBOSE
    declare -g FAME_DEBUG=
    SAVED_VERBOSE=$FAME_VERBOSE
    FAME_VERBOSE=$FAME_DEBUG
    quiet $*
    FAME_VERBOSE=$SAVED_VERBOSE
}

function yesno() {
    local RSP
    while true; do
    	read -p "$* (yes/no) ? " RSP
	[ "$RSP" = yes ] && return 0
	[ "$RSP" = no ] && return 1
	warn "'$RSP' is not yes or no!"
    done
}

function ispow2() {
    [ "$1" -eq 0 ] && return 0		# Explicit 0 is okay
    local -i T=$1
    [ $T -eq 0 ] && return 1		# Junk that evals to zero with -i
    # 512G (2^39) has a log error of 10**-17, so throw away noise.
    python -c "import math; e=round(math.log($1, 2), 5); exit(not(e == int(e)))"
    # Shell boolean values are inverse of Python, hence the "not" above.
    return $?
}

###########################################################################

function Gfree_or_die() {
        local GF NEEDED
	# $1 is the number of GB needed, $2-n is a description
	NEEDED=$1
	shift
	# df -BG is never zero, ie, it will round 5M -> 1G
	GF=`df -BG $FAME_DIR | awk '/^\// {print $4}'`
	let GF=${GF:0:-1}-1		# chomp the trailing G and fudge it down
	log "$* needs ${NEEDED}G of disk space; ${GF}G is available"
	[ $GF -lt $NEEDED ] && die "$* needs $NEEDED GB ( > $GF GB free)"
}

###########################################################################

function inDocker() {
    grep -Eq '^[[:digit:]]+:[[:alnum:]_,=]+:/docker/[[:xdigit:]]+$' /proc/$$/cgroup
}

function inHost() {	# More legible than "! inDocker"
    inDocker
    [ $? -eq 0 ] && return 1 || return 0
}

###########################################################################
# Helper for qemu-bridge-helper, contained in package qemu-system-common

function verify_QBH() {
    local ACL PATTERN QBH
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
    [ $? -ne 0 ] && log $PATTERN | quiet $SUDO tee -a $ACL

    # "Failed to parse default acl file" if these are wrong.
    debug $SUDO chown root:libvirt-qemu $ACL
    debug $SUDO chmod 640 $ACL

    return 0
}

###########################################################################
# Save original host values for final processing delivered from a container.

declare -A ONHOST=(
    [FAME_DIR]=$FAME_DIR
    [FAME_FAM]=$FAME_FAM
)

function fixup_Docker_environment() {
    inHost && return
    export FAME_DIR=$DOCKER_DIR
    export FAME_FAM=$DOCKER_DIR/`basename $FAME_FAM`
    export LOG=$DOCKER_DIR/`basename $LOG`
    export TEMPLATEIMG=$DOCKER_DIR/`basename $TEMPLATEIMG`
    export USER=`whoami`
}

function echo_environment() {
    local PREFIX VARS
    [ $# -gt 0 ] && PREFIX="$1 " || PREFIX=	# But no gratuitous space!
    echo "${PREFIX}http_proxy=$http_proxy"
    VARS=`env | grep FAME_ | cut -d= -f1 | sort`
    for V in $VARS; do
    	if [[ ${!ONHOST[@]} =~ $V ]]; then	# match keys
		VAL=${ONHOST[$V]}
    	else
		VAL=${!V}	# dereference V like a pointer
	fi
	echo "$PREFIX$V=$VAL"
    done
}

###########################################################################
# Check out major file system stuff. FAM must be under DIR in a
# container.  vmdebootstrap requires root, but there are other commands,
# especially in the host for running VMs.  Ass-u-me coreutils is installed.

[ `id -u` -ne 0 ] && SUDO="sudo -E" || SUDO=

declare -i FAME_SIZE_BYTES=0
FAME_SIZE=0G

function verify_environment() {
    local CMD LOOPS MISSING MAYBE NEED NEEDS PREV T TMP
    sep Verifying host environment

    # This goes into the virtual network name which has length limits.
    # virsh will define a net with a loooong name but fail on starting it.
    [ ${#FAME_HOSTBASE} -gt 8 ] && die "FAME_HOSTBASE must be <= 8 chars"

    # Close some obvious holes before SUDO
    unset LD_LIBRARY_PATH
    export PATH="/bin:/usr/bin:/sbin:/usr/sbin"

    # sudo has not yet been verified
    if [ -f $LOG ]; then
	PREV=$LOG.previous
	debug rm -f $PREV
	[  $? -eq 0 ] || die "Cannot rm $PREV, please do so"
	debug mv -f $LOG $LOG.previous # vmdebootstrap will rewrite it
	[ $? -eq 0 ] || die "Cannot mv $LOG, please remove it"
    fi
    log "`date`\n"
    chmod 666 $LOG
    [ $? -eq 0 ] || die "Cannot start $LOG"

    NEEDS=
    for V in FAME_DIR; do	# All others are optional or defaulted
	[ "${!V}" ] || NEEDS="$NEEDS $V"
    done
    [ "$NEEDS" ] && die "Set and export $NEEDS"

    fixup_Docker_environment	# May change a few working variables

    [ -d "$FAME_DIR" ] || die "$FAME_DIR does not exist"
    [ -w "$FAME_DIR" ] || die "$FAME_DIR is not writeable"

    # Another user submitted errata which may include
    # bison dh-autoreconf flex gtk2-dev libglib2.0-dev livbirt-bin zlib1g-dev
    [ -x /bin/which -o -x /usr/bin/which ] || die "Missing command 'which'"
    NEED="awk grep losetup qemu-img vmdebootstrap"
    inHost && NEED="$NEED brctl libvirtd qemu-system-x86_64 virsh"
    [ "$SUDO" ] && NEED="$NEED sudo"
    MISSING=
    for CMD in $NEED; do
	debug which $CMD || MISSING="$CMD $MISSING"
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

    # Got RAM/DRAM for the VMs?  Earlier QEMU had trouble booting this
    # environment in less than this space, could have been page tables
    # for larger IVSHMEM.  FIXME: force KiB values, verify against FAM_SIZE.
    [ $FAME_VDRAM -lt 786432 ] && die "FAME_VDRAM=$FAME_VDRAM KiB is too small"
    let TMP=${FAME_VDRAM}*${NODES}
    set -- `head -1 /proc/meminfo`
    [ $2 -lt $TMP ] && warn "Insufficient real RAM for $NODES nodes of $FAME_VDRAM KiB each"

    # It's no longer necessary to have FAM IFF this is for FAME-Z.
    # [ "${ONHOST[FAME_FAM]}" ] || die "FAME_FAM variable must be specified"

    if [ ! "$FAME_FAM" ]; then
    	[ "$FAME_FAMEZ" ] || \
    		die 'At least one of FAME_FAM / FAME_FAMEZ must be set'
    else
	[ -f "$FAME_FAM" ] || die "$FAME_FAM does not exist"
	[ -w "$FAME_FAM" ] || die "$FAME_FAM is not writeable"
	[[ `ls -l $FAME_FAM` =~ libvirt-qemu ]] || \
		die "$FAME_FAM must belong to group libvirt-qemu"
	[[ `ls -l $FAME_FAM` =~ ^-rw-rw-.* ]] || \
		die "$FAME_FAM must be RW by owner and group libvirt-qemu"

	# Is FAM sized correctly?  QEMU only eats IVSHMEM with power of 2 size.
	# This FAME_ variable is NOT exported.

	FAME_SIZE_BYTES=`stat -c %s "$FAME_FAM"`
	ispow2 $FAME_SIZE_BYTES || die "$FAME_FAM size is not a power of 2"

	# QEMU limit is a function of the pass-through host CPU and available
	# memory (about half of true free RAM plus a small fudge factor).
	# Max size is an ADVISORY because it may work.  This is coupled with
	# a new check in lfs_shadow.py; if the value is too big, IVSHMEM is
	# bad from the guest point of view.

	let TMP=$FAME_SIZE_BYTES/1024/1024/1024
	FAME_SIZE=${TMP}G		# NOT exported
	log "$FAME_FAM = $FAME_SIZE"
	[ $TMP -lt 1 ] && die "$FAME_FAM size $T is less than 1G"
	[ $TMP -gt 512 ] && warn "$FAME_FAM size $TMP is greater than 512G"
    fi

    # This needs to become smarter, looking for stale kpartx devices
    LOOPS=`$SUDO losetup -al | grep devicemapper | grep -v docker | wc -l`
    [ $LOOPS -gt 0 ] && die \
    	'losetup -al shows active loopback mounts, please clear them'

    # verified working QEMU versions, checked only to "three digits"
    if inHost; then
    	VERIFIED_QEMU_VERSIONS="2.6.0 2.8.0 2.8.1 2.11.1"
    	set -- `qemu-system-x86_64 -version`
    	# Use regex to check current version against VERIFIED_QEMU_VERSIONS.
    	# See man page for bash, 3.2.4.2 Conditional Constructs.  No quotes.
    	[[ $VERIFIED_QEMU_VERSIONS =~ ${4:0:5} ]] || \
    		die "qemu is not version" ${VERIFIED_QEMU_VERSIONS[*]}
    	verify_QBH
    fi

    # NOW, possibly rewrite FAME_L4FAME for use with build/repo containers.
    # Then insure it's reachable, otherwise it won't happen until after
    # the vmdebootstrap.

    if [[ $FAME_L4FAME =~ localhost ]]; then
	FAME_L4FAME=`echo $FAME_L4FAME | sed -e "s/localhost/$TORMSIP/"`
    fi
    wgetURL $FAME_L4FAME

    return 0
}

###########################################################################
# libvirt / virsh / qemu / kvm stuff

function libvirt_bridge() {
    local CMD NETXML VIRSH
    inDocker && return 0
    sep Configure libvirt network bridge \"$NETWORK\"

    NETXML=$FAME_DIR/${FAME_HOSTBASE}_network.xml
    cp templates/network.xml $NETXML
    sed -i -e "s.NETWORK.$NETWORK." $NETXML
    sed -i -e "s.HOSTBASE.$FAME_HOSTBASE." $NETXML
    sed -i -e "s/OCTETS123/$FAME_OCTETS123/" $NETXML

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

    # This also marks it persistent.  Or is it the net-autostart?
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
MOUNTDEV=

# Do not die() from in here or you might get infinite recursion.

function mount_image() {
    local BIND LOCALIMG
    if [ -d $MNT ]; then	# Always try to undo it
    	for BIND in $BINDREV; do
		[ -d $BIND ] && debug $SUDO umount $MNT$BIND
	done
    	debug $SUDO umount $MNT
	[ "$LAST_KPARTX" ] && debug $SUDO kpartx -d $LAST_KPARTX
	LAST_KPARTX=
	MOUNTDEV=
	debug $SUDO rmdir $MNT	# Leave no traces
    fi
    [ $# -eq 0 ] && return 0

    # Now the fun begins.  Make /etc/grub.d/[00_header|10_linux] happy
    LOCALIMG="$*"
    [ ! -f $LOCALIMG ] && LAST_KPARTX= && return 1
    debug $SUDO mkdir -p $MNT
    debug $SUDO kpartx -as $LOCALIMG

    [ $? -ne 0 ] && echo "kpartx of $LOCALIMG failed" >&2 && exit 1 # NO DIE()
    LAST_KPARTX=$LOCALIMG
    DEV=`losetup | awk -v mounted=$LAST_KPARTX '$0 ~ mounted {print $1}'`
    MOUNTDEV=/dev/mapper/`basename $DEV`p1
    debug $SUDO mount $MOUNTDEV $MNT
    if [ $? -ne 0 ]; then
    	$SUDO kpartx -d $LAST_KPARTX
	LAST_KPARTX=
	return 1	# let caller make decision on forward progress
    fi

    # bind mounts to make /etc/grub.d/XXX happy when they call grub-probe
    OKREV=
    for BIND in $BINDFWD; do
	debug $SUDO mkdir -p $MNT$BIND
	debug $SUDO mount --bind $BIND $MNT$BIND
	if [ $? -ne 0 ]; then
	    warn "Bind mount of $BIND failed"
	    [ "$OKREV" ] && for O in "$OKREV"; do debug $SUDO umount $MNT$O; done
	    debug $SUDO umount $MNT
	    return 1
	fi
	debug echo Bound $BIND
	OKREV="$BIND $OKREV"	# reverse order is important during failures
    done
    return 0
}

###########################################################################
# Tri-state return value

function validate_template_image() {
    local RET
    [ -f $TEMPLATEIMG ] || return 1		# File not found
    mount_image $TEMPLATEIMG || return 255	# aka return -1: corrupt
    test -d $MNT/home/$FAME_USER		# see vmdebootstrap --user
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
    local RC TMP
    if [ "$FAME_PROXY" ]; then	# may have come from http_proxy originally
    	if [ "${http_proxy:-}" ]; then
	    echo "http_proxy=$http_proxy (existing environment)"
	else
	    echo "http_proxy=$FAME_PROXY (from FAME_PROXY)"
	fi
	[ "${FAME_PROXY:0:7}" != "http://" ] && FAME_PROXY="http://$FAME_PROXY"
	http_proxy=$FAME_PROXY
	https_proxy=${https_proxy:-${http_proxy}}	# yes reuse it
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
    log "No proxy setting can be ascertained"	# Not necessarily bad
    return 0
}

###########################################################################
# Add a package, most uses are fulfilled from the second FAME_L4FAME.
# Remember APT::Get::AllowUnauthenticated was set earlier.
# $1: Full name of package
# $2: Revision (optional)

function install_one() {
    local DG PKG RET VER
    PKG=$1
    [ $# -eq 2 ] && VER="=$2" || VER=
    [ "$VER" ] && DG='--allow-downgrades' || DG=
    log Installing $PKG$VER
    quiet $SUDO chroot $MNT apt-cache show $PKG$VER	# "search" is fuzzy
    [ $? -ne 0 ] && warn "No candidate matches $PKG" && return 1

    # Here's a day I'll never get back :-)  DEBIAN_FRONTEND env var is the
    # easiest way to get this per-package (debconf-get/set would be needed).
    # "man bash" for -c usage, it's not what you think.  The outer double
    # quotes send a single arg to quiet() while allowing evaluation of $PKG.
    # The inner single quotes are preserved across the chroot to create a
    # single arg for "bash -c".
    quiet $SUDO chroot $MNT /bin/bash -c \
	"'DEBIAN_FRONTEND=noninteractive; apt-get --yes $DG install $PKG$VER'"
    [ $? -ne 0 ] && warn "Installation of $PKG$VER failed" && return 1

    # The package name can be a (short) regex so be careful with the paranoia
    $SUDO chroot $MNT dpkg -l | grep -q $PKG
    RET=$?
    [ $RET -ne 0 ] && warn "dpkg -l after install \"$PKG\" failed"
    return $RET
}

###########################################################################
# add-apt-repository clutters /etc/apt/sources.list too much for my taste.
# $1: file name under /etc/apt/sources.list.d
# $2 - $n: active line to go into that file
# Assumes image is already mounted at $MNT.  Yes, same file is cumulative.
# Any failure here is fatal as it's assumed the new repo needs to be used
# during the lifetime of this script.

function wgetURL() {
    local URL
    URL=$1
    [[ ! $URL =~ ^http ]] && die "wgetURL $URL does not start with http[s]"
    [[ $URL =~ https ]] && CERT="--no-check-certificate" || CERT=
    [[ $URL =~ localhost|127.|$FAME_OCTETS123 ]] && PROXY="--no-proxy" || PROXY=
    log "wget $URL..."
    debug wget $PROXY $CERT --timeout=10 -O /dev/null $URL
    [ $? -ne 0 ] && die "Cannot reach $URL"
}

function apt_add_repository() {
    local SOURCES URL
    SOURCES="/etc/apt/sources.list.d/$1"
    shift
    URL=`tr ' ' '\n' <<< "$*" | grep '^http'`
    wgetURL $URL
    cat << EOSOURCES | quiet $SUDO tee -a $MNT$SOURCES
# Added by emulation_configure.bash `date`

$* 
EOSOURCES
    quiet $SUDO chroot $MNT apt-get update
    [ $? -ne 0 ] && die "Cannot refresh $SOURCES"
    return 0
}

function apt_key_add() {
    local URL
    URL=$1
    shift
    quiet $SUDO chroot $MNT sh -c "'http_proxy=$http_proxy https_proxy=$https_proxy curl -fsSL $URL | apt-key add -'"
    [ $? -ne 0 ] && die "Error adding $* official GPG key"
    return 0
}

function apt_mark_hold() {
    quiet $SUDO chroot $MNT apt-mark hold "$1"
    [ $? -ne 0 ] && warn "Cannot hold $1" && return 1	# not fatal
    return 0
}

###########################################################################
# Setup things so "apt-get install docker-ce" works.  Adapted from
# https://docs.docker.com/engine/installation/linux/docker-ce/debian/#set-up-the-repository
# Assumes image is already mounted at $MNT.

# These versions are known to work together.
# https://download.docker.com/linux/debian/dists/stretch/pool/stable/amd64/
DOCKER_VERSION=17.03.2~ce-0~debian-stretch
KUBERNETES_VERSION="1.8.2"
KUBEADM_VERSION="$KUBERNETES_VERSION-00"
KUBELET_VERSION="$KUBERNETES_VERSION-00"
KUBECTL_VERSION="$KUBERNETES_VERSION-00"

function install_Docker_Kubernetes() {
    local RELEASE
    RELEASE=stretch
    sep "Installing Docker $DOCKER_VERSION and Kubernetes $KUBERNETES_VERSION"

    grep -q $RELEASE $MNT/etc/os-release || die "Docker was expecting $RELEASE"

    # apt-transport-https is needed for the repos, curl/gpg for keys, plus dependencies
    for P in apt-transport-https ca-certificates curl gnupg2 software-properties-common
    do
    	install_one $P || die "Failed Docker/k8s requirement $P"
    done

    apt_key_add https://download.docker.com/linux/debian/gpg Docker

    apt_add_repository docker-ce.list deb [arch=amd64] \
    	https://download.docker.com/linux/debian $RELEASE stable

    install_one docker-ce $DOCKER_VERSION
    [ $? -ne 0 ] && warn "No Docker; skipping Kubernetes" && return 1

    quiet $SUDO chroot $MNT /usr/sbin/adduser $FAME_USER docker

    # And now k8s.  Use xenial repo as no kubeadm build for jessie or stretch.

    apt_key_add https://packages.cloud.google.com/apt/doc/apt-key.gpg Kubernetes
    apt_add_repository kubernetes.list deb http://apt.kubernetes.io/ kubernetes-xenial main
    [ $? -ne 0 ] && warn "Couldn't add Kubernetes repo; skipping packages" && return 1

    install_one kubelet $KUBELET_VERSION
    install_one kubeadm $KUBEADM_VERSION
    install_one kubectl $KUBECTL_VERSION
}

###########################################################################
# Add the repo, pull the packages.  Yes multistrap might do this all at
# once but this script is evolutionary from a trusted base.  And then
# it still needs to have grub installed.

function transmogrify_l4fame() {
    local APTCONF E KV RESOLVdotCONF
    mount_image $TEMPLATEIMG || return 1
    sep "Extending the image template with L4FAME"
    APTCONF="$MNT/etc/apt/apt.conf.d/00FAME.conf"

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

    RESOLVdotCONF=/etc/resolv.conf
    quiet $SUDO unlink $MNT$RESOLVdotCONF
    quiet $SUDO tee $MNT$RESOLVdotCONF <<< "nameserver	$TORMSIP" # first
    grep nameserver $RESOLVdotCONF | quiet $SUDO tee -a $MNT$RESOLVdotCONF

    apt_add_repository l4fame.list deb \[trusted=yes\] $FAME_L4FAME testing main

    install_one "$FAME_KERNEL"	# Always use quotes.
    [ $? -ne 0 ] && die "Cannot install L4FAME kernel"
    apt_mark_hold "$FAME_KERNEL"

    # Auxiliary packages for building things like autofs (dkms) for Docker.
    # Retrieve full version via the chroot environment, not the local one.
    set -- `$SUDO chroot $MNT apt-cache search $FAME_KERNEL`
    KV=${1##linux-image-}
    [ "$KV" ] || die "Cannot retrieve full version from $FAME_KERNEL"

    # One of them is just a version, and the other is part of the name
    install_one "linux-headers-$KV"	 # "linux-headers" is a virt pkg
    install_one linux-libc-dev "${KV}-1" # Yes, -1

    # Installing a kernel took info from /proc and /sys that set up
    # /etc/fstab, but it's from the host system.  Fix that, along with
    # other things.  Then finish off L4FAME.

    common_config_files

    for E in l4fame-node; do
    	install_one $E || warn "Install of $E failed"
    done

    # install_Docker_Kubernetes		# Eats CPU, no one is using it

    mount_image

    return 0
}

###########################################################################
# /boot/grub/grub.cfg, built "on the host", has boot entries of the form
# linux /boot/vmlinux-4-14.9-l4fame+ root=UUID=xyzzy...
# Built under Docker, the entry is like
# linux /boot/vmlinux-4-14.9-l4fame+ roo=/dev/mapper/loop0p1
# That mapper file also exists during "on host" building, and I don't
# really know where the confusion takes place.  I'm guessing the root
# mount device in the chroot is different.  Just fix it.

function fixup_Docker_grub() {
    local GRUBCFG UUID
    inHost && return
    GRUBCFG=$MNT/boot/grub/grub.cfg
    mount_image $TEMPLATEIMG || die "Can't mount $TEMPLATEIMG for grub fixup"
    UUID=`blkid -o export $MOUNTDEV | grep -E '^UUID='`
    [ "$UUID" ] || die "Cannot recover UUID from $MOUNTDEV"
    sed -i -e "s.root=$MOUNTDEV.root=$UUID." $GRUBCFG
    mount_image
}

###########################################################################
# This takes about six minutes if the mirror is unproxied on a LAN.  YMMV.

function manifest_template_image() {
    local KEY RET SUFFIX VMD VMCFG VMDVER
    sep Handle VM golden image $TEMPLATEIMG

    validate_template_image
    RET=$?
    [ $RET -eq 255 ] && quiet $SUDO rm -f $TEMPLATEIMG # corrupt
    if [ $RET -eq 0 ]; then
    	yesno "Re-use existing $TEMPLATEIMG"
	[ $? -eq 0 ] && log "Keep existing $TEMPLATEIMG" && return 0
    else
	Gfree_or_die $FAME_VFS_GBYTES "New template image"
    fi
    log Creating new $TEMPLATEIMG from $FAME_MIRROR

    # Different versions eat different arguments.  --dump-config used to be
    # an easy test but with later versions the arg list started getting
    # unwieldy.  Use multiple VMD files.  VERIFIED_XXX means it's truly been
    # tested at least once.  The lists are easier than numeric comparisons. 
    # Use regex to check the current version against different lists.

    VMDVER=`vmdebootstrap --version`
    local -A VERIFIED
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
    log Using $VMDCFG

    VMD="$SUDO vmdebootstrap --no-default-configs --config=$VMDCFG"

    # vmdebootstrap calls debootstrap which makes a loopback mount for
    # the image under construction, like /dev/mapper/loop0p1.  It should
    # be possible to construct a status bar based on df of that mount.
    # NOTE: killing the script here may leave a dangling mount that
    # interferes with subsequent runs, but doesn't complain properly.
    # Later versions of vmdebootstrap don't take both --image and --tarball.

    VMDLOG=$LOG.vmd
    $VMD --log=$VMDLOG --image=$TEMPLATEIMG --size=${FAME_VFS_GBYTES}G \
    	--mirror=$FAME_MIRROR --owner=$SUDO_USER --user="${FAME_USER}/iforgot"
    RET=$?
    quiet $SUDO chown $SUDO_USER "$VMDLOG" 	# --owner bug
    if [ $RET -ne 0 -o ! -f $TEMPLATEIMG ]; then
	BAD=`mount | grep '/dev/loop[[:digit:]]+p[[:digit:]]+'`
	[ "$BAD" ] && warn "mount of $BAD may be a problem" | tee -a $LOG
    	die "Build of $TEMPLATEIMG failed"
    fi

    validate_template_image || die "Validation of fresh $TEMPLATEIMG failed"

    # "pklist" is hardcoded here
    quiet $SUDO mv -f dpkg.list $FAME_DIR/${FAME_HOSTBASE}_dpkg.list

    transmogrify_l4fame || die "Addition of L4FAME repo failed"

    fixup_Docker_grub	# after all chances to update_grub

    return 0
}

###########################################################################
# Helper for cloning into current image at $MNT.  A few one-liners and a
# few loops.

function common_config_files() {
    local ETCHOSTS FSTAB I RET SUDOER

    # Yes, the word "NODEXX", which will be sedited later
    echo NODEXX | quiet $SUDO tee $MNT/etc/hostname

    echo "http_proxy=$FAME_PROXY" | quiet $SUDO tee -a $MNT/etc/environment

    #------------------------------------------------------------------
    SUDOER=$MNT/etc/sudoers.d/FAME_phraseless

    echo "$FAME_USER	ALL=(ALL:ALL) NOPASSWD: ALL" | quiet $SUDO tee $SUDOER

    #------------------------------------------------------------------
    ETCHOSTS=$MNT/etc/hosts

    quiet $SUDO tee $ETCHOSTS << EOHOSTS
127.0.0.1	localhost
127.1.0.1	NODEXX

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$TORMSIP	torms vmhost `hostname`

EOHOSTS

    # Not really needed with dnsmasq doing DNS but helps when nodes are down
    # as dnsmasq omits them.
    for I in `seq $NODES`; do
    	echo $FAME_OCTETS123.$I "${FAME_HOSTBASE}$I" | \
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
# Copy, emit, convert: the qcow2 images are 1/10th the size of the template.

function clone_VMs()
{
    local DOTSSH F N2 NEWIMG NODEXX QCOW2 TARGET TMP
    sep Generating file system images for $NODES virtual machines
    for N2 in `seq -f '%02.0f' $NODES`; do
    	NODEXX=$FAME_HOSTBASE$N2
	QCOW2="$FAME_DIR/$NODEXX.qcow2"
	if [ -f $QCOW2 ]; then
	    yesno "Re-use existing $QCOW2"
	    [ $? -eq 0 ] && log "Keep existing $QCOW2" && continue
	    $SUDO rm -f $QCOW2
	else
	    # For a short time there will be two new files.  The
	    # average size of a new QCOW2 image is about 2G.
	    let TMP=$FAME_VFS_GBYTES+2
	    Gfree_or_die $TMP "Temp raw image plus new qcow2"
	fi

	log "Customize $NODEXX..."
    	NEWIMG="$FAME_DIR/$NODEXX.img"
	quiet cp $TEMPLATEIMG $NEWIMG
	mount_image $NEWIMG || die "Cannot mount $NEWIMG"

	# Fixup files
	for F in etc/hostname etc/hosts; do
		TARGET=$MNT/$F
		quiet $SUDO sed -i -e "s/NODEXX/$NODEXX/" $TARGET
	done

	DOTSSH=$MNT/home/$FAME_USER/.ssh
	quiet $SUDO mkdir -m 700 $DOTSSH
	quiet $SUDO cp templates/id_rsa.nophrase     $DOTSSH
	quiet $SUDO cp templates/id_rsa.nophrase.pub $DOTSSH
	quiet $SUDO cp templates/id_rsa.nophrase.pub $DOTSSH/authorized_keys

	# FIXME: "$FAME_USER" user in the chroot might be different from the
	# host but this is a reasonable assumption on a fresh vmdebootstrap.
	quiet $SUDO chown -R 1000:1000 $DOTSSH
	quiet $SUDO chmod 400 $DOTSSH/id_rsa.nophrase
	quiet $SUDO tee $DOTSSH/config << EOSSHCONFIG
ConnectTimeout 5
StrictHostKeyChecking no

Host node*
	User $FAME_USER
	IdentityFile ~/.ssh/id_rsa.nophrase
EOSSHCONFIG

	# FIXME: this belongs in package scripting
    	quiet $SUDO chroot $MNT /bin/systemctl enable tm-lfs

	mount_image

	log Converting $NEWIMG into $QCOW2
	quiet qemu-img convert -f raw -O qcow2 $NEWIMG $QCOW2
	quiet rm -f $NEWIMG

	# systemd "Creating volatile files and directories" will hang if
	# the mounted FS is not readable.  That starts at the qcow2 file.
	if inHost; then
		$SUDO chown libvirt-qemu:libvirt-qemu $QCOW2
	else
		# See the Makefile
		$SUDO chown $LVQUID:$LVQGID $QCOW2
	fi
	$SUDO chmod 660 $QCOW2
    done
    return 0
}

###########################################################################
# Create an INI file for the Librarian.  If node count is a power of 2
# then there's no roundoff error (ie, lost books).

function emit_LFS_INI() {
    local -i BOOK_SIZE_BYTES BOOK_SIZE_MB BOOKS_PER_NODE TOTAL_BOOKS
    local -r INIFILE=${ONHOST[FAME_DIR]}/node_fame.ini
    local EXTRA

    [ ! "$FAME_FAM" ] && return 0

    # Start with 8M books, keep total books under 10000
    let BOOK_SIZE_BYTES=8*1048576
    let TOTAL_BOOKS=$FAME_SIZE_BYTES/$BOOK_SIZE_BYTES
    while [ $TOTAL_BOOKS -gt 10000 ]; do
    	let BOOK_SIZE_BYTES *= 2
    	let TOTAL_BOOKS=$FAME_SIZE_BYTES/$BOOK_SIZE_BYTES
    done

    let BOOK_SIZE_MB=$BOOK_SIZE_BYTES/1048576	# unit == MB
    let BOOKS_PER_NODE=$TOTAL_BOOKS/$NODES	# unit == Books

    if ispow2 $FAME_SIZE_BYTES; then
	EXTRA=
    else
    	EXTRA='(Not a power of 2 so some NVM may not be usable.)'
    fi

cat << EOINI > $INIFILE
# Auto-created `date`
# Total emulated FAM in $FAME_FAM == $FAME_SIZE
#       $EXTRA
# $ sudo mkdir -p /var/hpetm
# $ sudo BOOK_REGISTER -d /var/hpetm/librarian.db $INIFILE
# BOOK_REGISTER is either tm-book-register or book_register.py, see the docs

[global]
node_count = $NODES
book_size_bytes = ${BOOK_SIZE_MB}M
nvm_size_per_node = ${BOOKS_PER_NODE}B
EOINI

    sep "\nLibrarian config file in $INIFILE"
    return 0
}

###########################################################################
# If apparmor is loaded/enabled, then per
# https://libvirt.org/drvqemu.html#securitysvirtaa,
# libvirtd makes a profile for each domain in /etc/apparmor.d/libvirt-<UUID>.
# This happens when the domain is STARTED.  It is driven from the template
# found in /etc/apparmor.d/libvirt/TEMPLATE.qemu.
# In the definition file, <qemu:commandline> is considered dangerous and
# emits a "Domain id=XX is tainted: custom-argv" warning in 
# /var/log/libvirt/qemu/<domain>.log.  However, the FAM backing store file
# itself is outside the auspices of the AA profile, and the VM startup is 
# aborted with Permission denied.  There are three options:
# 1. Remove apparmor.  Dodgy, and maybe not always possible.
# 2. Reduce the profile to complaint mode instead of enforcement.  Better but
#    might be considered too lax, plus it needs the apparmor-utils package.
# 3. Add the FAM file directly to the profile for the VM.  We have a winner!
#    Adjust the template file, actually.

# Linux Mint 19 has a larger abstractions/libvirt-qemu which precludes the
# use of any file in /tmp or /var/tmp.  This is a common place for people to
# put the IVSHMSG socket for FAME-Z so try to warn them.  "deny" seems to
# be forever, ie, it can't be counteracted by a subsequent "allow".

function fixup_apparmor() {
    local BASEARMOR FAM_STANZA FAMEZ_STANZA FMT
    quiet $SUDO aa-enabled
    [ $? -ne 0 ] && return 0	# Either not installed or not enabled

    # Each one is optional, they probably aren't both empty...
    [ ! "$FAME_FAM" -a ! "$FAME_FAMEZ" ] && return 0

    sep "Fixing up apparmor"

    # Idiot checks: you cannot undo apparmor "deny" and Linux Mint 19 uses it.
    # Yes, FAME_FAM could be there too but it's highly unlikely.

    BASEARMOR=/etc/apparmor.d/abstractions/libvirt-qemu
    FMT="apparmor denies use of %s by libvirt (FAME_FAMEZ=$FAME_FAMEZ)"
    if [ "$FAME_FAMEZ" ]; then
	# Superfluous now but I might not be done with it...
	egrep 'deny\s+/tmp/' $BASEARMOR >/dev/null 2>&1
	[ $? -eq 0 -a "${FAME_FAMEZ:0:5}" = /tmp/ ] && \
    	    die `printf "$FMT" /tmp`
	egrep 'deny\s+/var/tmp/' $BASEARMOR >/dev/null 2>&1
	[ $? -eq 0 -a "${FAME_FAMEZ:0:5}" = /var/ ] && \
    	    die `printf "$FMT" /var/tmp`
    fi

    # Execute
    FAM_STANZA=
    FAMEZ_STANZA=
    [ "$FAME_FAM" ] && FAM_STANZA="\"$FAME_FAM\" rw,"
    [ "$FAME_FAMEZ" ] && FAMEZ_STANZA="\"$FAME_FAMEZ\" rw,"

    TEMPLATE=/etc/apparmor.d/libvirt/TEMPLATE.qemu
    SAVED=$TEMPLATE.original
    [ ! -f $SAVED ] && $SUDO cp $TEMPLATE $SAVED
    cat <<EOPROFILE | sudo tee $TEMPLATE >/dev/null
#
# This profile is for the domain whose UUID matches this file.
# It's from a template modified for FAME:
# https://github.com/FabricAttachedMemory/Emulation
#

#include <tunables/global>

profile LIBVIRT_TEMPLATE {
  #include <abstractions/libvirt-qemu>
  $FAM_STANZA
  $FAMEZ_STANZA
}
EOPROFILE

    return 0
}

###########################################################################
# Create virt-manager files

function emit_libvirt_XML() {
    local CPUMODEXX DOMTYPEXX MACADDRXX N2 NODEXML NODEXX QCOWXX SRCXML
    local FAME_IVSHMEM FAMEZ_IVSHMSG
    sep "Creating libvirt XML files and helper script"

    # The mailbox is implicitly defined and passed by famez_server.py
    # so its declaration is not needed here (although it can be used).
    # That keeps the size specification where it belongs.  Specify the
    # max number of vectors the FAME-Z server will ever use (16).
    # Keeping it smaller means less likelihood of running out, although
    # that's probably paranoid.

    FAME_IVSHMEM=
    if [ "$FAME_FAM" ]; then
    	read -r -d '' FAME_IVSHMEM << EOIVSHMEM
    <qemu:arg value='-object'/>
    <qemu:arg value='memory-backend-file,mem-path=${ONHOST[FAME_FAM]},size=$FAME_SIZE,id=FAM,share=on'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='ivshmem-plain,memdev=FAM'/>
EOIVSHMEM
	# Now turn linefeeds into two-character backslash-n.  Thanks Google!
	FAME_IVSHMEM="${FAME_IVSHMEM//$'\n'/\\n}"
    fi

    FAMEZ_IVSHMSG=
    if [ "$FAME_FAMEZ" ]; then		# Yes, true, 1, whatever
	FAME_FAMEZ="$FAME_DIR/${FAME_HOSTBASE}_socket"
    	read -r -d '' FAMEZ_IVSHMSG << EOIVSHMSG
    <qemu:arg value='-chardev'/>
    <qemu:arg value='socket,id=FAMEZ,path=$FAME_FAMEZ'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='ivshmem-doorbell,chardev=FAMEZ,vectors=16'/>
EOIVSHMSG
	# Now turn linefeeds into two-character backslash-n.  Thanks Google!
	FAMEZ_IVSHMSG="${FAMEZ_IVSHMSG//$'\n'/\\n}"
    fi

    for N2 in `seq -f '%02.0f' $NODES`; do
	NODEXX=$FAME_HOSTBASE$N2
	# This pattern is recognized by tm-lfs as the implicit node number
	MACADDRXX="$HPEOUI:${N2}:${N2}:${N2}"
	NODEXML=$FAME_DIR/$NODEXX.xml
	# Referenced inside nodeXX.xml
	QCOWXX=${ONHOST[FAME_DIR]}/$NODEXX.qcow2

	# Characterize this host for some final virsh tweaks.
	grep -q 'model name.*AMD' /proc/cpuinfo
	[ $? -eq 0 ] && MODEL=amd || MODEL=intel
	SRCXML=templates/node.$MODEL.xml
	cp -f $SRCXML $NODEXML

	grep -q '^flags.* vmx .*' /proc/cpuinfo	# Virtual-machine acceleration
	if [ $? -eq 0 ]; then
		DOMTYPEXX=kvm
		CPUMODEXX=host-passthrough
	else
		DOMTYPEXX=qemu		# VMware workstation on Windows
		CPUMODEXX=host-model
	fi

	sed -i -e "s!DOMTYPEXX!$DOMTYPEXX!" $NODEXML
	sed -i -e "s!CPUMODEXX!$CPUMODEXX!" $NODEXML
	sed -i -e "s!NODEXX!$NODEXX!" $NODEXML
	sed -i -e "s!QCOWXX!$QCOWXX!" $NODEXML
	sed -i -e "s!MACADDRXX!$MACADDRXX!" $NODEXML
	sed -i -e "s!NETWORK!$NETWORK!" $NODEXML
	sed -i -e "s!FAME_VDRAM!$FAME_VDRAM!" $NODEXML
	sed -i -e "s!FAME_VCPUS!$FAME_VCPUS!" $NODEXML

	# sed -i -e "s!FAME_FAM!${ONHOST[FAME_FAM]}!" $NODEXML
	# sed -i -e "s!FAME_SIZE!$FAME_SIZE!" $NODEXML

	sed -i -e "s!FAME_IVSHMEM!${FAME_IVSHMEM}!" $NODEXML
	sed -i -e "s!FAMEZ_IVSHMSG!${FAMEZ_IVSHMSG}!" $NODEXML
    done

    NODE_VIRSH=${FAME_HOSTBASE}_virsh.sh
    echo "virsh files ${FAME_HOSTBASE}XX.xml are in ${ONHOST[FAME_DIR]}"
    echo "Change directory to ${ONHOST[FAME_DIR]} and run $NODE_VIRSH"

    NODE_VIRSH=${ONHOST[FAME_DIR]}/$NODE_VIRSH
    cp templates/node_virsh.sh $NODE_VIRSH
    sed -i -e "s/OCTETS123/$FAME_OCTETS123/" $NODE_VIRSH
    sed -i -e "s/USER/$FAME_USER/" $NODE_VIRSH

    return 0
}

###########################################################################
# MAIN - do a few things before set -u

if [ $# -ne 1 -o "${1:0:1}" = '-' ]; then	# Show current settings
	echo_environment
	inHost && echo -e "\nusage: `basename $0` [ -h|? ] [ VMcount ]"
	exit 0
fi
typeset -ir NODES=$1	# will evaluate to zero if non-integer

set -u

[ $NODES -lt 1 -o $NODES -gt 32 ] && die "VM count is not in range 1-32"

# Could lead to rounding error and "loss" of NVM; not fatal.
ispow2 $NODES || warn "VM count is not a power of 2"

trap "rm -f debootstrap.log; exit 0" TERM QUIT INT HUP EXIT # always empty

verify_environment

fixup_apparmor

libvirt_bridge

expose_proxy

manifest_template_image

clone_VMs

emit_LFS_INI

emit_libvirt_XML

# After all transformatons are finished, save it for next time.
echo_environment export > $FAME_DIR/${FAME_HOSTBASE}_env.sh

exit 0
