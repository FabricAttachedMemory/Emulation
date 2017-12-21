FROM debian:stretch-slim AS build

LABEL description="Run emulation_configure.bash inside a Debian container"

WORKDIR /Emulation

COPY emulation_configure.bash .

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    kpartx \
    qemu-utils \
    vmdebootstrap \
    wget \
    ; \
    rm -rf /var/lib/apt/lists/* ; \
    ls

# Default PWD is WORKDIR
ENTRYPOINT [ "./emulation_configure.bash" ]
