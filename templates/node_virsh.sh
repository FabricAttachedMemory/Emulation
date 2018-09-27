#!/bin/bash

# Manage the collection of nodeXX.xml files.

DIRECTIVE=${1-}

[ -z "$FAME_FAM" -o ! -f "$FAME_FAM" ] && echo 'Missing $FAME_FAM' >&2 && exit 1

set -u

###########################################################################

function die()
{
	echo $* >&2
	exit 1
}

###########################################################################
# MAIN.  Set a few globals, then check group membership.

EXECUTION_DIRECTORY="$( dirname "${BASH_SOURCE[0]}" )"
cd $EXECUTION_DIRECTORY
NODESXML=`find ./ -name "${FAME_HOSTBASE}[0-3][0-9].xml" -printf "%f\n"`
NODESDOM=`echo $NODESXML | sed 's/\.xml//g'`
[ "$FAME_VERBOSE" ] && echo $NODESDOM
[ "$NODESDOM" ] || die "No $FAME_HOSTBASE artifacts found in $FAME_DIR"

[ `id -u` -ne 0 ] && SUDO="sudo -E" || SUDO=
VIRSH="$SUDO virsh"

[[ `groups` =~ libvirt-qemu ]] || \
	die "You must belong to group libvirt-qemu"

[[ `ls -l $FAME_FAM` =~ libvirt-qemu ]] || \
	die "$FAME_FAM must belong to group libvirt-qemu"

[[ `ls -l $FAME_FAM` =~ ^-rw-rw-.* ]] || \
	die "$FAME_FAM must be RW by owner and group libvirt-qemu"

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
		ssh l4mdc@$IP sudo shutdown -h 0
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
