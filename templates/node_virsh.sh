#!/bin/bash

# Manage the collection of nodeXX.xml files.

DIRECTIVE=${1-}

[ -z "$FAME_FAM" -o ! -f "$FAME_FAM" ] && echo 'Missing $FAME_FAM' >&2 && exit 1

set -u

###########################################################################
# If apparmor is loaded/enabled, then per
# https://libvirt.org/drvqemu.html#securitysvirtaa,
# libvirtd makes a profile for each domain in /etc/apparmor.d/libvirt-<UUID>.
# This happens when the domain is STARTED.
# In the definition file, <qemu:commandline> is considered dangerous and
# emits a "Domain id=XX is tainted: custom-argv" warning in 
# /var/log/libvirt/qemu/<domain>.log.  However, the FAM backing store file
# itself is outside the auspices of the AA profile, and the VM startup is 
# aborted with Permission denied.  There are three options:
# 1. Remove apparmor.  Dodgy, and maybe not always possible.
# 2. Reduce the profile to complaint mode instead of enforcement.  Better
#    but might be considered too lax, plus it needs the apparmor-utils
#    package.
# 3. Add the FAM file directly to the profile for the VM.  We have a winner!
# Chicken-and-egg: the profile is not generated until the START of the
# domain.  The TEMPLATE.qemu file seems like a logical place to do it
# until too many FAM files get stuffed in there...but it's cleaner than
# one false start and modifying the per-domain files.


function apparmor_fixup() {
	$SUDO aa-status >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		TEMPLATE=/etc/apparmor.d/libvirt/TEMPLATE.qemu
		ORIG=$TEMPLATE.orig
		[ ! -f $ORIG ] && $SUDO cp $TEMPLATE $ORIG
		cat <<EOPROFILE | sudo tee $TEMPLATE >/dev/null
#
# This profile is for the domain whose UUID matches this file.
# It's from a template modified for FAME:
# https://github.com/FabricAttachedMemory/Emulation
#

#include <tunables/global>

profile LIBVIRT_TEMPLATE {
  #include <abstractions/libvirt-qemu>
  "$FAME_FAM" rw,
}
EOPROFILE

	fi
	return 0
}

###########################################################################
# MAIN.  Set a few globals, then check group membership.

EXECUTION_DIRECTORY="$( dirname "${BASH_SOURCE[0]}" )"
cd $EXECUTION_DIRECTORY
NODESXML=`find ./ -name "node*.xml" -printf "%f\n"`
NODESDOM=`echo $NODESXML | sed 's/\.xml//g'`

[ `id -u` -ne 0 ] && SUDO="sudo -E" || SUDO=
VIRSH="$SUDO virsh"

if [[ ! `groups` =~ libvirt-qemu ]]; then
	echo "You must belong to group libvirt-qemu" >&2
	exit 1
fi
if [[ ! `ls -l $FAME_FAM` =~ libvirt-qemu ]]; then
	echo "$FAME_FAM must belong to group libvirt-qemu" >&2
	exit 1
fi
if [[ ! `ls -l $FAME_FAM` =~ ^-rw-rw-.* ]]; then
	echo "$FAME_FAM must be RW by owner and group libvirt-qemu" >&2
	exit 1
fi

# Wheres' the beef?

case "$DIRECTIVE" in

define)
	for XML in $NODESXML; do $VIRSH define $XML; done
	exit 0
	;;

destroy)
	for DOM in $NODESDOM; do $VIRSH destroy $DOM; done
	exit 0
	;;

start)
	apparmor_fixup
	for DOM in $NODESDOM; do
		$VIRSH start $DOM
	done
	exit 0
	;;

status)
	$VIRSH list --all | egrep -- 'Name|----|node'
	exit 0
	;;

stop|shutdown)	# Get id_rsa.nophrase as your identity file
	N=1
	for NODE in $NODESDOM; do
		IP="192.168.42.$N"
		echo -n "$NODE ($IP): "
		ssh l4tm@$IP sudo shutdown -h 0
		let N+=1
	done
	exit 0
	;;

undefine)
	for DOM in $NODESDOM; do $VIRSH undefine $DOM; done
	exit 0
	;;

esac

echo "usage: `basename $0` [ define | destroy | start | status | shutdown | stop | undefine ]"
exit 0
