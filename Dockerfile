FROM debian:stretch-slim

LABEL description="Run emulation_configure.bash inside a Debian container"

ENV DEBIAN_FRONTEND noninteractive
ENV WD /Emulation

WORKDIR ${WD}

COPY emulation_configure.bash .

RUN apt-get update && apt-get install -y --no-install-recommends \
	ca-certificates curl wget \
	# bridge-utils grep kpartx mawk mount qemu-utils vmdebootstrap \
	; \
	rm -rf /var/lib/apt/lists/*; \
	ls

CMD [ "bash" ]
