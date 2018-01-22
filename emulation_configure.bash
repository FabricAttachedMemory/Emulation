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
# Note: FAME_DIR was originally TMPDIR, but that variable is suppressed
# by glibc on setuid programs which breaks under certain uses of sudo.

# Blanks for FAME_DIR and FAME_FAM will throw an error later.
FAME_DIR=${FAME_DIR:-}
[ "$FAME_DIR" ] && FAME_DIR=`dirname "$FAME_DIR/xxx"`	# chomp trailing slash
export FAME_DIR

export FAME_FAM=${FAME_FAM:-}

export FAME_USER=${FAME_USER:-l4mdc}

export FAME_VCPUS=${FAME_VCPUS:-2}		# No idiot checks yet

export FAME_VDRAM=${FAME_VDRAM:-786432}

export FAME_MIRROR=${FAME_MIRROR:-http://ftp.us.debian.org/debian}

export FAME_PROXY=${FAME_PROXY:-$http_proxy}
http_proxy=${http_proxy:-}			# Yes, after FAME_PROXY

export FAME_VERBOSE=${FAME_VERBOSE:-}	# Default: mostly quiet; "yes" for more

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
typeset -r NETWORK=${HOSTUSERBASE}_emul		# libvirt name length limits
typeset -r HPEOUI="48:50:42"
typeset -r OCTETS123=192.168.42			# see fabric_emul.net.xml
typeset -r TORMSIP=$OCTETS123.254
typeset -r DOCKER_DIR=/fame_dir			# See Makefile and Docker.md

# Can be reset under Docker so no typeset -r
junk=`basename $0`
LOG=$FAME_DIR/${junk%%.*}.log
TEMPLATEIMG=$FAME_DIR/${HOSTUSERBASE}_template.img

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
    	echo $* | tee -a $LOG
    	eval $* 2>&1 | tee -a $LOG
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

function verify_environment() {
    sep Verifying host environment

    # Close some obvious holes before SUDO
    unset LD_LIBRARY_PATH
    export PATH="/bin:/usr/bin:/sbin:/usr/sbin"

    NEEDS=
    for V in FAME_DIR FAME_FAM; do
	[ "${!V}" ] || NEEDS="$NEEDS $V"
    done
    [ "$NEEDS" ] && echo "Set and export variable(s) $NEEDS" >&2 && exit 1

    fixup_Docker_environment	# May change a few working variables

    [ -d "$FAME_DIR" ] || die "$FAME_DIR does not exist"
    [ -w "$FAME_DIR" ] || die "$FAME_DIR is not writeable"
    [ "${ONHOST[FAME_FAM]}" ] || die "FAME_FAM variable must be specified"
    [ -f "$FAME_FAM" ] || die "$FAME_FAM does not exist"
    [ -w "$FAME_FAM" ] || die "$FAME_FAM is not writeable"

    # sudo has not yet been verified
    if [ -f $LOG ]; then
	PREV=$LOG.previous
	quiet rm -f $PREV
	[  $? -eq 0 ] || die "Cannot rm $PREV, please do so"
	quiet mv -f $LOG $LOG.previous # vmdebootstrap will rewrite it
	[ $? -eq 0 ] || die "Cannot mv $LOG, please remove it"
    fi
    echo -e "`date`\n" > $LOG
    chmod 666 $LOG
    [ $? -eq 0 ] || die "Cannot start $LOG"

    # Another user submitted errata which may include
    # bison dh-autoreconf flex gtk2-dev libglib2.0-dev livbirt-bin zlib1g-dev
    [ -x /bin/which -o -x /usr/bin/which ] || die "Missing command 'which'"
    NEED="awk grep losetup qemu-img vmdebootstrap"
    inHost && NEED="$NEED brctl libvirtd qemu-system-x86_64 virsh"
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

    # Got RAM/DRAM for the VMs?  Earlier QEMU had trouble booting this
    # environment in less than this space, could have been page tables
    # for larger IVSHMEM.  FIXME: force KiB values, verify against FAM_SIZE.
    [ $FAME_VDRAM -lt 786432 ] && die "FAME_VDRAM=$FAME_VDRAM KiB is too small"
    let TMP=${FAME_VDRAM}*${NODES}
    set -- `head -1 /proc/meminfo`
    [ $2 -lt $TMP ] && die "Insufficient real RAM for $NODES nodes of $FAME_VDRAM KiB each"

    # Is FAM sized correctly?
    T=`stat -c %s "$FAME_FAM"`
    # Shell boolean values are inverse of Python.  512G (2^39) has a log
    # error of 10**-17, so throw away noise.
    python -c "import math; e=round(math.log($T, 2), 5); exit(not(e == int(e)))"
    [ $? -ne 0 ] && die "$FAME_FAM size $T is not a power of 2"

    # QEMU limit is a function of the (pass-through) host CPU and available
    # memory (about half of true free RAM plus a fudge factor?).  Max size
    # is an ADVISORY because it may work.  This is coupled with a new
    # check in lfs_shadow.py; if the value is too big, IVSHMEM is bad
    # from the guest point of view.
    let TMP=$T/1024/1024/1024
    FAME_SIZE=${TMP}G	# NOT exported
    quiet echo "$FAME_FAM = $FAME_SIZE"
    [ $TMP -lt 1 ] && die "$FAME_FAM size $T is less than 1G"
    [ $TMP -gt 512 ] && echo "$FAME_FAM size $TMP is greater than 512G"

    # This needs to become smarter, looking for stale kpartx devices
    LOOPS=`$SUDO losetup -al | grep devicemapper | grep -v docker | wc -l`
    [ $LOOPS -gt 0 ] && die \
    	'losetup -al shows active loopback mounts, please clear them'

    # verified working QEMU versions, checked only to "three digits"
    if inHost; then
    	VERIFIED_QEMU_VERSIONS="2.6.0 2.8.0 2.8.1"
    	set -- `qemu-system-x86_64 -version`
    	# Use regex to check the current version against VERIFIED_QEMU_VERSIONS.
    	# See man page for bash, 3.2.4.2 Conditional Constructs.  No quotes.
    	[[ $VERIFIED_QEMU_VERSIONS =~ ${4:0:5} ]] || \
    		die "qemu is not version" ${VERIFIED_QEMU_VERSIONS[*]}
    	verify_QBH
    fi

    # Space for 2 raw image files, the tarball, all qcows, and slop
    let GNEEDED=16+1+$NODES+1
    let KNEEDED=1000000*$GNEEDED
    TMPFREE=`df "$FAME_DIR" | awk '/^\// {print $4}'`
    [ $TMPFREE -lt $KNEEDED ] && die "$FAME_DIR has less than $GNEEDED G free"

    echo_environment export > $FAME_DIR/env.sh	# For next time

    return 0
}

###########################################################################
# libvirt / virsh / qemu / kvm stuff

function libvirt_bridge() {
    inDocker && return 0
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
MOUNTDEV=

function mount_image() {
    if [ -d $MNT ]; then	# Always try to undo it
    	for BIND in $BINDREV; do
		[ -d $BIND ] && quiet $SUDO umount $MNT$BIND
	done
    	quiet $SUDO umount $MNT
	[ "$LAST_KPARTX" ] && quiet $SUDO kpartx -d $LAST_KPARTX
	LAST_KPARTX=
	MOUNTDEV=
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
	return 1	# let caller make decision on forward progress
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
    if [ "$FAME_PROXY" ]; then	# may have come from http_proxy originally
    	if [ "${http_proxy:-}" ]; then
	    echo "http_proxy=$http_proxy (existing environment)"
	else
	    echo "http_proxy=$FAME_PROXY (from FAME_PROXY)"
	fi
	[ "${FAME_PROXY:0:7}" != "http://" ] && FAME_PROXY="http://$FAME_PROXY"
	http_proxy=$FAME_PROXY
	https_proxy=${https_proxy:-${http_proxy}}
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
# $1: Full name of package
# $2: Revision (optional)

function install_one() {
    PKG=$1
    [ $# -eq 2 ] && VER="=$2" || VER=
    echo Installing $PKG$VER
    quiet $SUDO chroot $MNT apt-cache show $PKG	# "search" is fuzzy match
    RET=$?
    [ $RET -ne 0 ] && echo "No candidate matches $PKG" >&2 && return $RET

    # Here's a day I'll never get back :-)  DEBIAN_FRONTEND env var is the
    # easiest way to get this per-package (debconf-get/set would be needed).
    # "man bash" for -c usage, it's not what you think.  The outer double
    # quotes send a single arg to quiet() while allowing evaluation of $PKG.
    # The inner single quotes are preserved across the chroot to create a
    # single arg for "bash -c".
    quiet $SUDO chroot $MNT /bin/bash -c \
	"'DEBIAN_FRONTEND=noninteractive; apt-get --yes install $PKG$VER'"
    RET=$?
    [ $RET -ne 0 ] && echo "Install failed" >&2 && return $RET

    quiet $SUDO chroot $MNT dpkg -l $PKG	# Paranoia
    RET=$?
    [ $RET -ne 0 ] && echo "dpkg -l after install failed" >&2 && return $RET
    return 0
}

###########################################################################
# add-apt-repository clutters /etc/apt/sources.list too much for my taste.
# $1: file name under /etc/apt/sources.list.d
# $2 - $n: active line to go into that file
# Assumes image is already mounted at $MNT.  Yes, same file is cumulative.
# Any failure here is fatal as it's assumed the new repo needs to be used
# during the lifetime of this script.

function apt_add_repository() {
    SOURCES="/etc/apt/sources.list.d/$1"
    echo "Updating apt with $SOURCES..."
    shift
    URL=`tr ' ' '\n' <<< "$*" | grep '^http'`
    echo "Contacting $URL..."
    wget -O /dev/null $URL > /dev/null 2>&1
    [ $? -ne 0 ] && die "Cannot reach $URL"

    cat << EOSOURCES | sudo tee -a $MNT$SOURCES
# Added by emulation_configure.bash `date`

$* 
EOSOURCES
    quiet $SUDO chroot $MNT apt-get update
    [ $? -ne 0 ] && die "Cannot refresh $SOURCES"
}

function apt_key_add() {
    URL=$1
    shift
    quiet $SUDO chroot $MNT sh -c "'http_proxy=$http_proxy https_proxy=$https_proxy curl -fsSL $URL | apt-key add -'"
    [ $? -ne 0 ] && die "Error adding $* official GPG key"
}

function apt_mark_hold() {
    quiet $SUDO chroot $MNT apt-mark hold "$1"
    [ $? -ne 0 ] && echo "Cannot hold $1" >&2	# not fatal
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
    sep "Installing Docker $DOCKER_VERSION and Kubernetes $KUBERNETES_VERSION"

    RELEASE=stretch
    grep -q $RELEASE $MNT/etc/os-release || die "Docker was expecting $RELEASE"

    # apt-transport-https is needed for the repos, curl/gpg for keys, plus dependencies
    for P in apt-transport-https ca-certificates curl gnupg2 software-properties-common
    do
    	install_one $P || die "Failed Docker/k8s requirement $P"
    done

    apt_key_add https://download.docker.com/linux/debian/gpg Docker

    apt_add_repository docker-ce.list deb [arch=amd64] \
    	https://download.docker.com/linux/debian $RELEASE stable

    install_one docker-ce $DOCKER_VERSION || die "Could not install Docker"

    quiet $SUDO chroot $MNT /usr/sbin/adduser $FAME_USER docker

    # And now k8s.  Use xenial repo as no kubeadm build for jessie or stretch.

    apt_key_add https://packages.cloud.google.com/apt/doc/apt-key.gpg Kubernetes
    apt_add_repository kubernetes.list deb http://apt.kubernetes.io/ kubernetes-xenial main

    install_one kubelet $KUBELET_VERSION || die "kubelet install failed"
    install_one kubeadm $KUBEADM_VERSION || die "kubeadm install failed"
    install_one kubectl $KUBECTL_VERSION || die "kubectl install failed"
}

###########################################################################
# Add the repo, pull the packages.  Yes multistrap might do this all at
# once but this script is evolutionary from a trusted base.  And then
# it still needs to have grub installed.

function transmogrify_l4fame() {
    mount_image $TEMPLATEIMG || return 1
    sep "Extending template with L4FAME: updating sources..."
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

    # A repo container on this host should be expressed as localhost.

    if [[ $FAME_L4FAME =~ localhost ]]; then
	USED_L4FAME=`echo $FAME_L4FAME | sed -e "s/localhost/$TORMSIP/"`
    else
	USED_L4FAME=$FAME_L4FAME
    fi

    apt_add_repository l4fame.list deb \[trusted=yes\] $USED_L4FAME testing main

    install_one "$FAME_KERNEL"	# Always use quotes.
    [ $? -ne 0 ] && die "Cannot install L4FAME kernel"
    apt_mark_hold "$FAME_KERNEL"

    # Auxiliary packages for building things like autofs (dkms) for Docker
    KV=${FAME_KERNEL##linux-image-}
    if [ "$KV" ]; then
    	install_one "linux-headers-$KV"
    	install_one "linux-libc-dev_$KV"	# Yes, underscore
    fi

    # Installing a kernel took info from /proc and /sys that set up
    # /etc/fstab, but it's from the host system.  Fix that, along with
    # other things.  Then finish off L4FAME.

    common_config_files

    for E in l4fame-node; do
    	install_one $E || echo "$E failed" >&2
    done

    install_Docker_Kubernetes

    mount_image

    return $RET
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
    inHost && return
    GRUBCFG=$MNT/boot/grub/grub.cfg
    mount_image $TEMPLATEIMG || die "Can't mount $TEMPLATEIMG for grub fixup"
    UUID=`blkid -o export $MOUNTDEV | grep -E '^UUID='`
    [ "$UUID" ] || die "Cannot recover UUID from $MOUNTDEV"
    sed -ie "s.root=$MOUNTDEV.root=$UUID." $GRUBCFG
    mount_image
}

###########################################################################
# This takes about six minutes if the mirror is unproxied on a LAN.  YMMV.

function manifest_template_image() {
    sep Handle VM golden image $TEMPLATEIMG

    validate_template_image
    RET=$?
    [ $RET -eq 255 ] && quiet $SUDO rm -f $TEMPLATEIMG # corrupt
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

    VMDLOG=$LOG.vmd
    $VMD --log=$VMDLOG --image=$TEMPLATEIMG \
    	--mirror=$FAME_MIRROR --owner=$SUDO_USER --user="${FAME_USER}/iforgot"
    RET=$?
    quiet $SUDO chown $SUDO_USER "$VMDLOG" 	# --owner bug
    if [ $RET -ne 0 -o ! -f $TEMPLATEIMG ]; then
	BAD=`mount | grep '/dev/loop[[:digit:]]+p[[:digit:]]+'`
	[ $BAD ] && echo "mount of $BAD may be a problem" | tee -a $LOG
    	die "Build of $TEMPLATEIMG failed"
    fi

    validate_template_image || die "Validation of fresh $TEMPLATEIMG failed"

    quiet $SUDO mv -f dpkg.list $FAME_DIR	# "pklist" is hardcoded here

    transmogrify_l4fame || die "Addition of L4FAME repo failed"

    fixup_Docker_grub	# after all chances to update_grub

    return 0
}

###########################################################################
# Helper for cloning into current image at $MNT

function common_config_files() {

    # One-liners

    # Yes, the word "NEWHOST", which will be sedited later
    echo NEWHOST | quiet $SUDO tee $MNT/etc/hostname

    echo "http_proxy=$FAME_PROXY" | quiet $SUDO tee -a $MNT/etc/environment

    #------------------------------------------------------------------
    SUDOER=$MNT/etc/sudoers.d/FAME_phraseless

    echo "$FAME_USER	ALL=(ALL:ALL) NOPASSWD: ALL" | quiet $SUDO tee $SUDOER

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
	QCOW2="$FAME_DIR/$NEWHOST.qcow2"
	if [ -f $QCOW2 ]; then
	    yesno "Re-use $QCOW2"
	    [ $? -eq 0 ] && echo "Keep existing $QCOW2" && continue
	fi
	$SUDO rm -f $QCOW2

	echo "Customize $NEWHOST..."
    	NEWIMG="$FAME_DIR/$NEWHOST.img"
	quiet cp $TEMPLATEIMG $NEWIMG

	# Fixup files
	mount_image $NEWIMG || die "Cannot mount $NEWIMG"
	for F in etc/hostname etc/hosts; do
		TARGET=$MNT/$F
		quiet $SUDO sed -i -e "s/NEWHOST/$NEWHOST/" $TARGET
	done

	DOTSSH=$MNT/home/$FAME_USER/.ssh
	quiet $SUDO mkdir -m 700 $DOTSSH
	quiet $SUDO cp templates/id_rsa.nophrase     $DOTSSH
	quiet $SUDO cp templates/id_rsa.nophrase.pub $DOTSSH/authorized_keys
	# The "$FAME_USER" user in the chroot might be different from the host.

	# FIXME but this is a reasonable assumption on a fresh vmdebootstrap.
	quiet $SUDO chown -R 1000:1000 $DOTSSH
	quiet $SUDO chmod 400 $DOTSSH/id_rsa.nophrase
	quiet $SUDO tee $DOTSSH/config << EOSSHCONFIG
ConnectTimeout 5
StrictHostKeyChecking no

Host node*
	User $FAME_USER
	IdentityFile ~/.ssh/id_rsa.nophrase
EOSSHCONFIG

    	quiet $SUDO chroot $MNT systemctl enable tm-lfs

	mount_image

	echo Converting $NEWIMG into $QCOW2
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
# Create virt-manager files

function emit_libvirt_XML() {
    sep "\nvirsh files nodeXX.xml are in ${ONHOST[FAME_DIR]}"
    for N2 in `seq -f '%02.0f' $NODES`; do
	NODEXX=$HOSTUSERBASE$N2
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
	sed -i -e "s!FAME_VDRAM!$FAME_VDRAM!" $NODEXML
	sed -i -e "s!FAME_VCPUS!$FAME_VCPUS!" $NODEXML
	sed -i -e "s!FAME_FAM!${ONHOST[FAME_FAM]}!" $NODEXML
	sed -i -e "s!FAME_SIZE!$FAME_SIZE!" $NODEXML
    done
    cp templates/node_virsh.sh $FAME_DIR
    echo "Change directory to ${ONHOST[FAME_DIR]} and run node_virsh.sh"
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

[ "$NODES" -lt 1 -o "$NODES" -gt 40 ] && die "VM count is not in range 1-40"

trap "rm -f debootstrap.log; exit 0" TERM QUIT INT HUP EXIT # always empty

verify_environment

libvirt_bridge

expose_proxy

manifest_template_image

clone_VMs

emit_libvirt_XML

exit 0
