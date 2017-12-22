BASE:=emulation_configure
SCRIPT:=${BASE}.bash
IMG:=fame:${BASE}
CONT:=${BASE}
MYENV:=myenv

help:
	@echo "Target   Action"
	@echo "status   Show relevant Docker images and containers"
	@echo "env      Dump current $FAME_XXXX variables into ${MYENV}"
	@echo "build    Create the Docker image '${IMG}'"
	@echo "VMs      Run ${IMG} as ${CONT} and create VMs in ${FAME_OUTDIR}"
	@echo "clean    Stop and remove container ${CONT}"
	@echo "mrproper First clean, then remove image ${IMG}"
	@echo "debug    Run ${IMG} as ${CONT} and start bash"

env:
	@./${SCRIPT} | grep '=' | tee ${MYENV}

status:
	@docker images | grep -e REPOSITORY -e "${BASE}"
	@echo
	@docker ps -a | grep -e CONTAINER -e "${BASE}"

build:
	docker build --build-arg http_proxy=${http_proxy} --tag=${IMG} .

debug:
	docker run --name=${CONT} -it --entrypoint bash \
	-v ${FAME_OUTDIR}:/outdir --env-file=${MYENV} \
	--cap-add=ALL --privileged \
	--device=/dev/loop-control:/dev/loop-control:rwm \
	--device=/dev/loop0:/dev/loop0:rwm \
	--device=/dev/loop1:/dev/loop1:rwm \
	--device=/dev/loop2:/dev/loop2:rwm \
	--device=/dev/loop3:/dev/loop3:rwm \
	--device=/dev/loop4:/dev/loop4:rwm \
	--device=/dev/loop5:/dev/loop5:rwm \
	--device=/dev/loop6:/dev/loop6:rwm \
	--device=/dev/loop7:/dev/loop7:rwm \
	--device-cgroup-rule="c 10:236 mwr" \
	--device-cgroup-rule="c 10:237 mwr" \
	--device-cgroup-rule="b 254:* mwr" \
	${IMG}

clean:
	docker stop ${CONT} 2>/dev/null || true
	docker rm ${CONT} 2>/dev/null || true

mrproper:	clean
	docker rmi ${IMG} 2>/dev/null || true

rmi:	mrproper
