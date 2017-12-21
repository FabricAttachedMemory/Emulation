# Running emulation_configure.sh in a Docker container

This is a bunch of quick, loose notes taken during development, I promise
to clean it up.

1. export http_proxy=<wherever your proxy is>

1. $ ./emulation_configure.bash > myenv

1. Edit myenv to do the right thing

1. docker build --build-arg http_proxy=$http_proxy --tag=fame:emulation_configure .

1. docker run -it --rm --env-file=myenv fame:emulation_configure
   and verify values


