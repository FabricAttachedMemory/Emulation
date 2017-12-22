FROM debian:stretch-slim AS build

LABEL description="Run emulation_configure.bash inside a Debian container"

WORKDIR /Emulation

# Directory targets are not imputed and must be explicit.
COPY emulation_configure.bash .
COPY templates templates/

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    file \
    iproute2 \
    kpartx \
    qemu-utils \
    strace \
    vim \
    vmdebootstrap \
    wget

ENTRYPOINT [ "./emulation_configure.bash" ]
