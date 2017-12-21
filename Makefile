IMG:=fame:emulation_configure
CONT:=junk

help:
	@echo Target    Action
	@echo build     Create the Docker image "${IMG}"
	@echo bash	Turn ${IMG} into ${CONT} and start bash
	@echo VMs	Turn ${IMG} into ${CONT} and create VMs in ${FAME_OUTDIR}
	@echo clean	Stop and remove ${CONT}
	@echo clean	First clean, then remove ${IMG}

build:
	docker build --build-arg http_proxy=${http_proxy} --tag=${IMG} .

bash:
	docker run --name=${CONT} -it --entrypoint bash \
	-v ${FAME_OUTDIR}:/outdir --env-file=myenv \
	--cap-add=ALL \
	--device=/dev/loop-control:/dev/loop-control:rwm \
	--device=/dev/loop0:/dev/loop0:rwm \
	--device=/dev/loop1:/dev/loop1:rwm \
	--device=/dev/loop2:/dev/loop2:rwm \
	--device=/dev/loop3:/dev/loop3:rwm \
	--device=/dev/loop4:/dev/loop4:rwm \
	--device=/dev/loop5:/dev/loop5:rwm \
	--device=/dev/loop6:/dev/loop6:rwm \
	--device=/dev/loop7:/dev/loop7:rwm \
	--device-cgroup-rule="c 10:236 mrw" \
	--device-cgroup-rule="c 10:237 mrw" \
	--device-cgroup-rule="b 254:* mrw" \
	${IMG}

clean:
	docker stop ${CONT} 2>/dev/null || true
	docker rm ${CONT} 2>/dev/null || true

mrproper:	clean
	docker rmi ${IMG} 2>/dev/null || true

rmi:	mrproper
