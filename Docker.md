# Running emulation_configure.sh in a Docker container

Not everyone runs Debian Stretch or Ubuntu 16++.   If you're on a Redhat,
Fedora, CentOS, or SuSE system, you can create VMs in a Docker container.
Then you can run the FAME VMs on your native host.

## Install Docker on your host system

[Follow the official Docker guide for your host OS.](https://docs.docker.com/engine/installation/)

## Creation of VMs and XML files on your host system

1. Two or three variables must be set and exported from your shell environment:

   ```
   export FAME_DIR=/absolute/path/to/some/directory
   export FAME_FAM=$FAME_DIR/FAM
   export http_proxy=http://your.proxy.here:1234/
   ```

   $FAME_FAM must appear in $FAME_DIR when using this container technique.

   If you don't need a proxy to clear a firewall (for apt-get), leave this variable unset.
   
1. Create $FAME_FAM to be the necessary size.  For a 16 G file,

   ```
   fallocate -l 16G $FAME_FAM
   chgrp libvirt-qemu $FAME_FAM
   chmod 660 $FAME_FAM
   ```

1. Create a file containing all environment variables for the container.

   '''
   cd <wherever>/Emulation
   make env
   '''

   This creates a file "myenv" in the current directory (the checkout from github).  Edit
   myenv as appropriate.

1. Check the status of relevant Docker images and containers.

   ```make status```

   Should be empty the first time this is run.

1. Create the Docker image

   ```make image```

   Takes about one minute.

1. Create and enter the Docker container

   ```make container```

   Creates the container from the image and runs it, leaving you at a shell prompt inside the container.

   From here you run the script just as if you were still on a native Debian/Ubuntu host.
   The golden image is first contstructed, and this can take tens of minutes depending
   on your network and host speed.  You will only see the prompt "Debootstrapping Stretch"
   for a long time.

   If you want to check the progress of the build, got to another termulator on your 
   host and 

   ```make shell```

   To run a second shell inside the build container.  "ps -ef" will get you a program
   listing in the container.  During deboostrapping you should see at least one "wget" process. 
   Subsequent "ps -ef" should show new wget commands.

1. Clean up the container

   ```make clean```

   Leaves the Docker image.  This is usually good enough for a rerun.

1. Remove all traces of container activity

   ```make mrproper```

When emulation_configure.bash finishes in the container, "exit" the shell and container.
cd $FAME_DIR and source the file "env.sh".  Now you can run "./node_virsh" as described
elsewhere.


