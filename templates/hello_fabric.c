// Copyright 2015 Hewlett Packard Enterprise Development LP

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License, version 2  as 
// published by the Free Software Foundation.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, write to the Free Software Foundation, Inc.,
// 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

// hello_fabric.c - First touch of Fabric-Attached Memory for The Machine
// from Hewlett Packard Enterprise.  Compile this on any of the VMs created
// by the configurator script.

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/utsname.h>

int main(int argc, char *argv[]) {
    int fd;
    struct utsname *buf;

    if ((fd = open("/mnt/fabric_emulation", O_RDWR)) == -1) {
	perror("open failed");
	exit(1);
    }
    if ((buf = mmap(NULL, 256, PROT_WRITE, MAP_SHARED, fd, 0)) == MAP_FAILED) {
	perror("mmap failed");
	exit(1);
    }
    uname(buf);
    munmap(buf, 256);
    printf("On the VM host, examine /dev/shm/fabric_emulation\n");
    exit(0);
}
