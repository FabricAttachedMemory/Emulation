FROM debian:stretch-slim AS build

LABEL description="Run emulation_configure.bash inside a Debian container"

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    kpartx \
    qemu-utils \
    vmdebootstrap \
    wget

WORKDIR /Emulation

COPY emulation_configure.bash .

ENTRYPOINT [ "./emulation_configure.bash" ]
