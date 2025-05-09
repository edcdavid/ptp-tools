LOCALBIN ?= $(shell pwd)/../bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)/x86_64/

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize

IMG_PREFIX ?= quay.io/deliedit/test

VALUES = lptpd cep ptpop krp base

podman-buildall: $(foreach v, $(VALUES), podman-build-$(v))

podman-build-%:
	sed -i 's/IfNotPresent/Always/g' ../bindata/linuxptp/ptp-daemon.yaml
	$(MAKE) clean-image VAR=$*;
	$(MAKE) build-image VAR=$*

podman-pushall: $(foreach v, $(VALUES), podman-push-$(v))

podman-push-%:
	podman manifest push ${IMG_PREFIX}:$*

build-image:
	podman manifest create ${IMG_PREFIX}:$(VAR)
	podman build --no-cache --platform linux/amd64,linux/arm64 -f Dockerfile.$(VAR)  --manifest ${IMG_PREFIX}:$(VAR)  ..

build-image-arm:
	podman manifest create ${IMG_PREFIX}:$(VAR)
	podman build --no-cache --platform linux/arm64  -f Dockerfile.$(VAR)  --manifest ${IMG_PREFIX}:$(VAR)  ..

build-image-amd:
	podman manifest create ${IMG_PREFIX}:$(VAR)
	podman build --no-cache --platform linux/amd64  -f Dockerfile.$(VAR)  --manifest ${IMG_PREFIX}:$(VAR)  ..

podman-build-tools:
	$(MAKE) clean-image VAR=tools
	$(MAKE) build-image-arm VAR=tools

podman-build-tools-amd64:
	$(MAKE) clean-image VAR=tools
	$(MAKE) build-image-amd VAR=tools-amd64

podman-push-tools:
	$(MAKE) push-image VAR=tools

clean-image:
	podman manifest rm ${IMG_PREFIX}:$(VAR) || true

deploy-all: 
	./scripts/customize-env.sh ${IMG_PREFIX} ../config/manager
	cd ../config/manager && $(KUSTOMIZE) edit set image controller=${IMG_PREFIX}:ptpop
	$(KUSTOMIZE) build ../config/default | kubectl apply -f -
	$(KUSTOMIZE) build ../config/custom | kubectl apply -f -
	kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "local-sc"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'
