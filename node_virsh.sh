#!/bin/bash

# Manage the collection of nodeXX.xml files.

DIRECTIVE=${1-}

set -u

NODESXML=`ls node*.xml`
NODESDOM=`echo $NODESXML | sed 's/\.xml//g'`

[ `id -u` = 0 ] && VIRSH="virsh" || VIRSH='sudo virsh'

case "$DIRECTIVE" in

define)
	for XML in $NODESXML; do $VIRSH define $XML; done
	exit 0
	;;

start)
	for DOM in $NODESDOM; do $VIRSH start $DOM; done
	exit 0
	;;

status)
	$VIRSH list --all | egrep -- 'Name|----|node'
	exit 0
	;;

stop|destroy)
	for DOM in $NODESDOM; do $VIRSH destroy $DOM; done
	exit 0
	;;

undefine)
	for DOM in $NODESDOM; do $VIRSH undefine $DOM; done
	exit 0
	;;

esac

echo "usage: `basename $0` [ define | start | stop | status | undefine ]"
exit 0
