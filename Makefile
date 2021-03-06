SHELL=/bin/bash -o pipefail

GOOS?=$(shell go env GOOS)
GOARCH?=$(shell go env GOARCH)
ifeq ($(GOARCH),arm)
	ARCH=armv7
else
	ARCH=$(GOARCH)
endif

GO_PKG=github.com/coreos/prometheus-operator
REPO?=quay.io/coreos/prometheus-operator
REPO_PROMETHEUS_CONFIG_RELOADER?=quay.io/coreos/prometheus-config-reloader
REPO_PROMETHEUS_OPERATOR_LINT?=quay.io/coreos/prometheus-operator-lint
TAG?=$(shell git rev-parse --short HEAD)
VERSION?=$(shell cat VERSION | tr -d " \t\n\r")

FIRST_GOPATH:=$(firstword $(subst :, ,$(shell go env GOPATH)))
CONTROLLER_GEN_BINARY := $(FIRST_GOPATH)/bin/controller-gen
GOJSONTOYAML_BINARY:=$(FIRST_GOPATH)/bin/gojsontoyaml
JB_BINARY:=$(FIRST_GOPATH)/bin/jb
PO_DOCGEN_BINARY:=$(FIRST_GOPATH)/bin/po-docgen
EMBEDMD_BINARY:=$(FIRST_GOPATH)/bin/embedmd

TYPES_V1_TARGET := pkg/apis/monitoring/v1/types.go
TYPES_V1_TARGET += pkg/apis/monitoring/v1/thanos_types.go

K8S_GEN_VERSION:=release-1.14
K8S_GEN_BINARIES:=informer-gen lister-gen client-gen
K8S_GEN_ARGS:=--go-header-file $(FIRST_GOPATH)/src/$(GO_PKG)/.header --v=1 --logtostderr

K8S_GEN_DEPS:=.header
K8S_GEN_DEPS+=$(TYPES_V1_TARGET)
K8S_GEN_DEPS+=$(foreach bin,$(K8S_GEN_BINARIES),$(FIRST_GOPATH)/bin/$(bin))

GO_BUILD_RECIPE=GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=0 go build -mod=vendor -ldflags="-s -X $(GO_PKG)/pkg/version.Version=$(VERSION)"
pkgs = $(shell go list ./... | grep -v /vendor/ | grep -v /test/ | grep -v /contrib/)

CONTAINER_CMD:=docker run --rm \
		-u="$(shell id -u):$(shell id -g)" \
		-v "$(shell go env GOCACHE):/.cache/go-build" \
		-v "$(PWD):/go/src/$(GO_PKG):Z" \
		-w "/go/src/$(GO_PKG)" \
		-e GO111MODULE=on \
		-e USER=deadbeef \
		quay.io/coreos/po-tooling

.PHONY: all
all: format generate build test

.PHONY: clean
clean:
	# Remove all files and directories ignored by git.
	git clean -Xfd .

############
# Building #
############

.PHONY: build
build: operator prometheus-config-reloader k8s-gen po-lint

.PHONY: operator
operator:
	$(GO_BUILD_RECIPE) -o $@ cmd/operator/main.go

.PHONY: prometheus-config-reloader
prometheus-config-reloader:
	$(GO_BUILD_RECIPE) -o $@ cmd/$@/main.go

.PHONY: po-lint
po-lint:
	$(GO_BUILD_RECIPE) -o po-lint cmd/po-lint/main.go

DEEPCOPY_TARGET := pkg/apis/monitoring/v1/zz_generated.deepcopy.go
$(DEEPCOPY_TARGET): $(CONTROLLER_GEN_BINARY)
	$(CONTROLLER_GEN_BINARY) object:headerFile=./.header \
		paths=./pkg/apis/monitoring/v1

CLIENT_TARGET := pkg/client/versioned/clientset.go
$(CLIENT_TARGET): $(K8S_GEN_DEPS)
	$(CLIENT_GEN_BINARY) \
	$(K8S_GEN_ARGS) \
	--input-base     "" \
	--clientset-name "versioned" \
	--input	         "$(GO_PKG)/pkg/apis/monitoring/v1" \
	--output-package "$(GO_PKG)/pkg/client"

LISTER_TARGET := pkg/client/listers/monitoring/v1/prometheus.go
$(LISTER_TARGET): $(K8S_GEN_DEPS)
	$(LISTER_GEN_BINARY) \
	$(K8S_GEN_ARGS) \
	--input-dirs     "$(GO_PKG)/pkg/apis/monitoring/v1" \
	--output-package "$(GO_PKG)/pkg/client/listers"

INFORMER_TARGET := pkg/client/informers/externalversions/monitoring/v1/prometheus.go
$(INFORMER_TARGET): $(K8S_GEN_DEPS) $(LISTER_TARGET) $(CLIENT_TARGET)
	$(INFORMER_GEN_BINARY) \
	$(K8S_GEN_ARGS) \
	--versioned-clientset-package "$(GO_PKG)/pkg/client/versioned" \
	--listers-package "$(GO_PKG)/pkg/client/listers" \
	--input-dirs      "$(GO_PKG)/pkg/apis/monitoring/v1" \
	--output-package  "$(GO_PKG)/pkg/client/informers"

.PHONY: k8s-gen
k8s-gen: \
	$(DEEPCOPY_TARGET) \
	$(CLIENT_TARGET) \
	$(LISTER_TARGET) \
	$(INFORMER_TARGET) \
	$(OPENAPI_TARGET)

.PHONY: image
image: .hack-operator-image .hack-prometheus-config-reloader-image

.hack-operator-image: Dockerfile operator
# Create empty target file, for the sole purpose of recording when this target
# was last executed via the last-modification timestamp on the file. See
# https://www.gnu.org/software/make/manual/make.html#Empty-Targets
	docker build --build-arg ARCH=$(ARCH) --build-arg OS=$(GOOS) -t $(REPO):$(TAG) .
	touch $@

.hack-prometheus-config-reloader-image: cmd/prometheus-config-reloader/Dockerfile prometheus-config-reloader
# Create empty target file, for the sole purpose of recording when this target
# was last executed via the last-modification timestamp on the file. See
# https://www.gnu.org/software/make/manual/make.html#Empty-Targets
	docker build --build-arg ARCH=$(ARCH) --build-arg OS=$(GOOS) -t $(REPO_PROMETHEUS_CONFIG_RELOADER):$(TAG) -f cmd/prometheus-config-reloader/Dockerfile .
	touch $@


##############
# Generating #
##############

vendor:
	go mod vendor

.PHONY: generate
generate: $(DEEPCOPY_TARGET) generate-crds bundle.yaml $(shell find Documentation -type f)

.PHONY: generate-in-docker
generate-in-docker:
	$(CONTAINER_CMD) make --always-make generate

.PHONY: generate-crds
generate-crds: $(CONTROLLER_GEN_BINARY) $(GOJSONTOYAML_BINARY) $(TYPES_V1_TARGET)
	GOOS=$(OS) GOARCH=$(ARCH) go run -v ./scripts/generate-crds.go --controller-gen=$(CONTROLLER_GEN_BINARY) --gojsontoyaml=$(GOJSONTOYAML_BINARY)

bundle.yaml: generate-crds $(shell find example/rbac/prometheus-operator/*.yaml -type f)
	scripts/generate-bundle.sh

scripts/generate/vendor: $(JB_BINARY) $(shell find jsonnet/prometheus-operator -type f)
	cd scripts/generate; $(JB_BINARY) install;

example/non-rbac/prometheus-operator.yaml: scripts/generate/vendor scripts/generate/prometheus-operator-non-rbac.jsonnet $(shell find jsonnet -type f)
	scripts/generate/build-non-rbac-prometheus-operator.sh

RBAC_MANIFESTS = example/rbac/prometheus-operator/prometheus-operator-cluster-role.yaml example/rbac/prometheus-operator/prometheus-operator-cluster-role-binding.yaml example/rbac/prometheus-operator/prometheus-operator-service-account.yaml example/rbac/prometheus-operator/prometheus-operator-deployment.yaml
$(RBAC_MANIFESTS): scripts/generate/vendor scripts/generate/prometheus-operator-rbac.jsonnet $(shell find jsonnet -type f)
	scripts/generate/build-rbac-prometheus-operator.sh

jsonnet/prometheus-operator/prometheus-operator.libsonnet: VERSION
	sed -i                                                            \
		"s/prometheusOperator: 'v.*',/prometheusOperator: 'v$(VERSION)',/" \
		jsonnet/prometheus-operator/prometheus-operator.libsonnet;

FULLY_GENERATED_DOCS = Documentation/api.md Documentation/compatibility.md
TO_BE_EXTENDED_DOCS = $(filter-out $(FULLY_GENERATED_DOCS), $(shell find Documentation -type f))

Documentation/api.md: $(PO_DOCGEN_BINARY) $(TYPES_V1_TARGET)
	$(PO_DOCGEN_BINARY) api $(TYPES_V1_TARGET) > $@

Documentation/compatibility.md: $(PO_DOCGEN_BINARY) pkg/prometheus/statefulset.go
	$(PO_DOCGEN_BINARY) compatibility > $@

$(TO_BE_EXTENDED_DOCS): $(EMBEDMD_BINARY) $(shell find example) bundle.yaml
	$(EMBEDMD_BINARY) -w `find Documentation -name "*.md" | grep -v vendor`


##############
# Formatting #
##############

.PHONY: format
format: go-fmt check-license shellcheck

.PHONY: go-fmt
go-fmt:
	go fmt $(pkgs)

.PHONY: check-license
check-license:
	./scripts/check_license.sh

.PHONY: shellcheck
shellcheck:
	docker run -v "$(PWD):/mnt" koalaman/shellcheck:stable $(shell find . -type f -name "*.sh" -not -path "*vendor*")

###########
# Testing #
###########

.PHONY: test
test: test-unit test-e2e

.PHONY: test-unit
test-unit:
	go test -race $(TEST_RUN_ARGS) -short $(pkgs) -count=1

test/instrumented-sample-app/certs/cert.pem test/instrumented-sample-app/certs/key.pem:
	cd test/instrumented-sample-app && make generate-certs

.PHONY: test-e2e
test-e2e: KUBECONFIG?=$(HOME)/.kube/config
test-e2e: test/instrumented-sample-app/certs/cert.pem test/instrumented-sample-app/certs/key.pem
	go test -timeout 55m -v ./test/e2e/ $(TEST_RUN_ARGS) --kubeconfig=$(KUBECONFIG) --operator-image=$(REPO):$(TAG) -count=1

############
# Binaries #
############

# generate k8s generator variable and target,
# i.e. if $(1)=informer-gen:
#
# INFORMER_GEN_BINARY=/home/user/go/bin/informer-gen
#
# /home/user/go/bin/informer-gen:
#	go get -u -d k8s.io/code-generator/cmd/informer-gen
#	cd /home/user/go/src/k8s.io/code-generator; git checkout release-1.14
#	go install k8s.io/code-generator/cmd/informer-gen
#
define _K8S_GEN_VAR_TARGET_
$(shell echo $(1) | tr '[:lower:]' '[:upper:]' | tr '-' '_')_BINARY:=$(FIRST_GOPATH)/bin/$(1)

$(FIRST_GOPATH)/bin/$(1):
	@go install -mod=vendor k8s.io/code-generator/cmd/$(1)

endef

$(foreach binary,$(K8S_GEN_BINARIES),$(eval $(call _K8S_GEN_VAR_TARGET_,$(binary))))

$(EMBEDMD_BINARY):
	@go install -mod=vendor github.com/campoy/embedmd

$(JB_BINARY):
	@go install -mod=vendor github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb

$(CONTROLLER_GEN_BINARY):
	@go install -mod=vendor sigs.k8s.io/controller-tools/cmd/controller-gen 

$(PO_DOCGEN_BINARY): $(shell find cmd/po-docgen -type f) $(TYPES_V1_TARGET)
	@go install -mod=vendor $(GO_PKG)/cmd/po-docgen

$(GOJSONTOYAML_BINARY):
	@go install -mod=vendor github.com/brancz/gojsontoyaml
