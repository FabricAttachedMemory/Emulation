BASE:=emulation_configure
SCRIPT:=${BASE}.bash
IMG:=fame:${BASE}
CONT:=${BASE}
MYENV:=myenv

$(shell [ ! -d "${FAME_DIR}" ] && echo "Missing FAME_DIR=${FAME_DIR}" >&2)
$(shell [ ! -f "${FAME_FAM}" ] && echo "Missing FAME_FAM=${FAME_FAM}" >&2)
LVQUID:=$(shell grep libvirt-qemu /etc/passwd | cut -d':' -f3)
LVQGID:=$(shell grep libvirt-qemu /etc/group  | cut -d':' -f3)

help:
	@echo "Target    Action"
	@echo "status    Show relevant Docker images and containers"
	@echo "env       Dump current FAME_XXXX variables into ${MYENV}"
	@echo "image     Create the Docker image"
	@echo "container Create the container and enter in a shell"
	@echo "shell     Re-enter the container in a shell"
	@echo "clean     Stop and remove container ${CONT}"
	@echo "mrproper  First clean, then remove image ${IMG}"

env:
	@./${SCRIPT} | grep '=' | sed -e 's/export //' | tee ${MYENV}

status:
	@docker images | grep -e REPOSITORY -e "${BASE}"
	@echo
	@docker ps -a | grep -e CONTAINER -e "${BASE}"

image:
	docker build --build-arg http_proxy=${http_proxy} --tag=${IMG} .

container:
	docker run --name=${CONT} -it --entrypoint bash \
	-e LVQUID=${LVQUID} -e LVQGID=${LVQGID} \
	-v ${FAME_DIR}:/fame_dir --env-file=${MYENV} \
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

shell:
	docker start ${CONT}
	docker exec -it ${CONT} bash

clean:
	docker stop ${CONT} 2>/dev/null || true
	docker rm ${CONT} 2>/dev/null || true

mrproper:	clean
	docker rmi ${IMG} 2>/dev/null || true

rmi:	mrproper
