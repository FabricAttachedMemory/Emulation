# Managing FAM in The Machine

There are multiple actors at work in The Machine to manage the cluster of nodes and the Fabric-Attached Memory (FAM) which they all share.

## Top-of-Rack Management Server (ToRMS)

In a true Machine cluster, a separate Linux system running on an HPE DL380 is used as a controlling resource and jump station.
It provides many functions, one of which is crucial to FAM management that needs to be duplicated even in the FAME environment.  Rather than a separate box, or even a separate VM, these functions are run directly on the VM host environment.  The full description of this program follows below, this paragraph serves to introduce the concept of the ToRMS.

## An API to abstract FAM

There are several challenges/goals to manage FAM in The Machine and/or FAME environments:
1. Pointer - any API should return a pointer to the application, which then proceeds to use the memory space.
1. Allocation - creation/reservation and sizing must be handled by the API
1. Persistence - the API must accommodate persistence in the FAM, ie, how can I find this block of memory tomorrow?
1. Attributes/metadata - size, time last accessed, permissions, etc.

All of these issues are adequately handled by the Linux filesystem API, specifically the first item.  mmap() is one of the few system calls that modifies the user space address map, and that's part of the FS API.  The other items (named blob, allocation, access) are clearly in the filesystem solution space.

### The Librarian File System

For The Machine we created a new filesystem, the "Librarian File System" or LFS.   FAM in The Machine hardware is organized into "books" of 8Gb, but still accessed by pages; hence the "Librarian" concept.   The Librarian File System is delivered as a suite of programs.  On the ToRMS in a Machine cluster (or, 

### Configuring and running The Librarian


