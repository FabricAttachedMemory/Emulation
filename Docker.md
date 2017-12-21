# Running emulation_configure.sh in a Docker container

This is a bunch of quick, loose notes taken during development, I promise
to clean it up.

docker build --build-arg http_proxy=$http_proxy --tag=fame:emulation_configure .

docker run -it --rm fame:emulation_configure


