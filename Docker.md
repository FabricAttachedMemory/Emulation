# Running emulation_configure.sh in a Docker container

This is a bunch of quick, loose notes taken during development, I promise
to clean it up.

1. export http_proxy=http://your.proxy.here:1234/
1. docker build --build-arg http_proxy=$http_proxy --tag=fame:emulation_configure .
1. $ ./emulation_configure.bash > myenv

   Edit myenv to have the right values.

1. docker run --env-file=myenv -it --rm fame:emulation_configure
   
   and verify values are as expected.


