# Managing FAM in The Machine

There are multiple actors at work in The Machine that manage the cluster of
nodes and the Fabric-Attached Memory (FAM) which they all share.  These same
programs are also used in the FAME environment.  Remember there is an
equivalence of a FAME VM to a single node in The Machine.  Refer to the
[background material on the wiki]
(https://github.com/FabricAttachedMemory/Emulation/wiki).

There's one more entity that must also appear in the FAME environment.

## An API to abstract FAM

There are several challenges/goals to manage FAM in The Machine and/or FAME environments:
1. Pointers - any API should return a pointer to the application, which then
proceeds to use the memory space.  The mechanics of this actually modify the
address space of the running process.
1. Allocation - creation/reservation and sizing must be handled by the API
1. Persistence - the API must accommodate persistence in the FAM, ie, how can I find this block of memory tomorrow?
1. Attributes/metadata - size, time last accessed, permissions, etc.

All of these issues are adequately served by the Linux filesystem API,
especially the first one.  mmap() is one of the few system calls that modifies
the user space address map, and that's part of the FS API.  The other items
(named blob, allocation, access) are clearly the purview of a filesystem.

### The Librarian File System

For The Machine we created a new filesystem, the "Librarian File System" or
LFS.   FAM in The Machine hardware is organized into "books" of 8Gb, but 
still accessed by pages; hence the "Librarian" concept.   The Librarian 
File System is delivered as a suite of programs.  The Librarian is
the metadata server for a disaggregated, distributed file system.  It is 
disaggregated because the metadata is NOT stored with the data in FAM.
Metadata is managed by an SQLite3 database which stores the FAM topology
(location and address of every book in FAM), allocations, timestamps,
active opens, etc.

Each node/VM runs a client daemon suite, the LFS daemon (or LFS FuSE daemon).
These daemons communicate over Ethernet to the Librarian for LFS metadata
manipulation.  But where does the Librarian run?

### Top-of-Rack Management Server (ToRMS)

In a true Machine cluster, a separate Linux system (NOT one of the nodes)
is used as a resource controller and jump station.
It provides multiple services, one of which is the Librarian.
The FAME environment must run the Librarian somewhere, but a separate
box from the host is NOT used.  These functions are run
directly on the host of the FAME environment.  In essence, the VM host
is the ToRMS to the FAME "nodes" (VMs).  A virtual bridge provided by
libvirt connects all the node VMs to the host network stack (and hence the
Librarian).

## Configuring and running The Librarian

The topology stored in the Librarian database is static.  The configuration
of all nodes (which enclosure and how much FAM) does not change over the
lifetime of a Machine boot.  The configuration is expressed as a [config
file in INI format](https://en.wikipedia.org/wiki/INI_file).  One program
in the LFS suite reads the INI file and creates the database, then the
Librarian can use it.

### Obtaining the Librarian

There are several ways to obtain the Librarian suite.  Each method delivers
a different path to critical programs to be run on the VM host.  For
later reference they will be referred to as

* BOOK_REGISTER - used to create the Librarian database
* LIBRARIAN - the metadata server for LFS

#### Debian installation of LFS suite

If your host system is Debian-based (Debian, Ubuntu, Mint) and of sufficient
freshness, you can grab .deb package files and install them.
(Browse to the HPE Software Delivery Repo "SDR")
[http://downloads.linux.hpe.com/SDR/index.html]
and select "l4fame Fabric Attached Memory Emulator".  From there click
the "Browse" button and follow "Debian -> pool -> main -> t -> tm-librarian"
and download two packages:

* python3-tm-librarian_X.YY-Z_all.deb - common files
* tm-librarian_X.YY-Z_all.deb - the Librarian

The third package, tm-lfs, is put on each VM image by the "emulation_configuration.bash" script in the Github project of this current README.

After installation there will be several programs in /usr/bin on your VM host:

* tm-book-register - Reads the INI file and creates the database
* tm-librarian - The LFS metadata server run on the VM host (or ToRMS)
* tm-lmp - "Librarian Monitoring Protocol", a ReST API for status
* fsck_lfs - Clean up the Librarian database

In this case,

* "<strong>BOOK_REGISTER</strong>" is /usr/bin/tm-book-register
* "<strong>LIBRARIAN</strong>" is /usr/bin/tm-librarian

#### Run from cloned repo of LFS suite

[Clone or download a source tarball of the Librarian from Github](https://github.com/FabricAttachedMemory/tm-librarian.git).  cd to the "src"
directory and you will find the same programs which can be run from "src":

* book_register.py - Reads the INI file and creates the database
* librarian.py - The LFS metadata server run on the VM host (or ToRMS)
* lmp.py - "Librarian Monitoring Protocol", a ReST API for status
* fsck_lfs.py - Clean up the Librarian database

In this case,

* "<strong>BOOK_REGISTER</strong>" is /path/to/cloned/repo/src/book_register.py
* "<strong>LIBRARIAN</strong>" is /path/to/cloned/repo/src/librarian.py

### Creating the INI file

The BOOK_REGISTER program creates the Librarian database file from an INI file.
The FAME environment can use a highly abbreviated form of the INI syntax.
In fact the primary script of the current project repo will create an INI file
for you.

[emulation_configure.bash](https://github.com/FabricAttachedMemory/Emulation/blob/master/emulation_configure.bash)
will create the file "$FAME_DIR/node_fame.ini" which can be used as-is.  Its
values are based on the size of $FAME_FAM, the number of nodes, and the
book size (default = 8M).  All values should be a power of two.  For example,
the INI file in FAME for a FAM of 32G and four nodes would be:

```
[global]
node_count = 4
book_size_bytes = 8M
nvm_size_per_node = 1024B
```

The unit for nvm_size_per_node is "books", thus 1024 8-megabyte books on
each of four nodes equals 32G.  The full INI format is much richer than
for real hardware but this compact form is usually sufficient for FAME.

### Create the Librarian database from the INI file

The default location for the database is in ```/var/hpetm/librarian.db``` so 

1. ```sudo mkdir -p /var/hpetm```
1. ```BOOK_REGISTER -d /var/hpetm/librarian.db file.ini```

### Run the Librarian

Once the database file is in the standard location,

```sudo LIBRARIAN --verbose 2```

If you've installed the Debian package on your system,

```sudo systemctl start tm-librarian```

When the node VMs are started they should automatically connect.
