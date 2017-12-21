# Running emulation_configure.sh in a Docker container

These quick, loose notes taken during development will be cleaned up.

Not everyone runs Debian Stretch or Ubuntu 16++.   If you're on a Redhat,
Fedora, CentOS, or SuSE system, you can create VMs in a Docker container.
Then you can run the FAME VMs on your native host.

## Install Docker on your host system

[Follow the official Docker guide for your host OS.](https://docs.docker.com/engine/installation/)

## Creation of VMs and XML files on your host system

1. Three environment variables must be set:

   ```
   export http_proxy=http://your.proxy.here:1234/
   export FAME_OUTDIR=/absolute/path/to/some/directory
   export FAME_FAM=$FAME_OUTDIR/FAM
   ```

1. ```docker build --build-arg http_proxy=$http_proxy --tag=fame:emulation_configure .```

1. ```./emulation_configure.bash > myenv```

   Edit myenv to have the right values.

1. ```docker run --env-file=myenv -it --rm fame:emulation_configure```
   
   and verify values are as expected.

1. ```docker run -v $FAME_OUTDIR:/outdir --env-file=myenv -it --rm fame:emulation_configure```

