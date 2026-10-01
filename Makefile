# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

SHELL           := /bin/bash -o nounset -o pipefail -o errexit
.DEFAULT_GOAL   := help
HELM_CHARTS_DIR ?= ../opennms-helm-charts
CHART           := charts/opennms-vpa
EXTRA           ?=
BUILD_DIR       := build

.PHONY: help
help:
	@echo "Targets:"
	@echo "  vendor        Link HELM_CHARTS_DIR (feat/vpa-hooks) into vendor/"
	@echo "  deps          Build umbrella dependencies"
	@echo "  lint          helm lint the umbrella"
	@echo "  unittest      helm-unittest suites of the umbrella"
	@echo "  test-scripts  shellcheck and run the shell tests"
	@echo "  test-tools    Run Python tool tests"
	@echo "  render        Render the umbrella and validate with kubeconform"
	@echo "  check-public  Fail on content that must not be in this public repo"
	@echo "  test          All of the above checks"

.PHONY: vendor
vendor:
	@for f in core:resizePolicy minion:resizePolicy minion:heapFromCgroup; do \
	  c=$${f%%:*}; k=$${f##*:}; \
	  grep -q "^$$k:" "$(HELM_CHARTS_DIR)/charts/$$c/values.yaml" 2>/dev/null || \
	    { echo "missing VPA hook '$$k' in $(HELM_CHARTS_DIR)/charts/$$c. Check out feat/vpa-hooks there."; exit 1; }; \
	done
	@mkdir -p vendor
	@ln -sfn "$(abspath $(HELM_CHARTS_DIR))" vendor/opennms-helm-charts
	@echo "vendor/opennms-helm-charts -> $(abspath $(HELM_CHARTS_DIR))"

.PHONY: deps
deps: vendor
	helm dependency update $(CHART)

.PHONY: lint
lint: deps
	helm lint $(CHART)

.PHONY: unittest
unittest: deps
	helm unittest $(CHART)

.PHONY: test-scripts
test-scripts:
	@for t in tests/*_test.sh lab/tests/*_test.sh; do [ -e "$$t" ] || continue; shellcheck -S warning "$$t" && bash "$$t"; done
	@shellcheck -x -S warning scripts/*.sh $$(ls lab/scripts/*.sh lab/phase0/*.sh campaign/*.sh 2>/dev/null)

.PHONY: test-tools
test-tools:
	python3 -m unittest discover -s tools/tests -v

.PHONY: render
render: deps
	@mkdir -p $(BUILD_DIR)
	helm template poc $(CHART) --namespace poc > $(BUILD_DIR)/render.yaml
	kubeconform -strict -ignore-missing-schemas -summary $(BUILD_DIR)/render.yaml

.PHONY: check-public
check-public:
	scripts/check-public.sh

.PHONY: test
test: lint unittest test-scripts test-tools render check-public

LAB_ENV   := lab/lab.env
LAB_STATE := lab/.state
LAB_SSH    = ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(LAB_STATE)/known_hosts

.PHONY: lab-up
lab-up:
	@test -f $(LAB_ENV) || { echo "Create $(LAB_ENV) from lab/lab.env.example"; exit 1; }
	@mkdir -p $(LAB_STATE)
	@source $(LAB_ENV); \
	  lab/scripts/pve-vm.sh create vpa-k8s $$K8S_VMID $$K8S_IP 16 49152 200 lab/cloud-init/k8s-user-data.yaml.tmpl; \
	  lab/scripts/pve-vm.sh create vpa-loadgen $$LOADGEN_VMID $$LOADGEN_IP 8 8192 40 lab/cloud-init/loadgen-user-data.yaml.tmpl; \
	  for ip in $${K8S_IP%/*} $${LOADGEN_IP%/*}; do \
	    until $(LAB_SSH) -o ConnectTimeout=5 lab@$$ip true 2>/dev/null; do sleep 10; done; \
	    $(LAB_SSH) lab@$$ip cloud-init status --wait; \
	  done
	@$(MAKE) --no-print-directory lab-kubeconfig

.PHONY: lab-kubeconfig
lab-kubeconfig:
	@mkdir -p $(LAB_STATE)
	@source $(LAB_ENV); $(LAB_SSH) lab@$${K8S_IP%/*} cat .kube/config > $(LAB_STATE)/kubeconfig
	@chmod 600 $(LAB_STATE)/kubeconfig
	KUBECONFIG=$(LAB_STATE)/kubeconfig kubectl get nodes -o wide

.PHONY: lab-down
lab-down:
	@source $(LAB_ENV); \
	  lab/scripts/pve-vm.sh destroy vpa-loadgen $$LOADGEN_VMID; \
	  lab/scripts/pve-vm.sh destroy vpa-k8s $$K8S_VMID
	rm -rf $(LAB_STATE)

.PHONY: lab-addons
lab-addons:
	lab/scripts/cluster-addons.sh

.PHONY: lab-sources
lab-sources:
	lab/scripts/source-pool.sh

.PHONY: phase0-mechanism
phase0-mechanism:
	lab/phase0/resize-check.sh

KUBECONFIG_LAB := $(LAB_STATE)/kubeconfig

.PHONY: deploy
deploy: deps
	KUBECONFIG=$(KUBECONFIG_LAB) helm upgrade --install poc $(CHART) --namespace poc --create-namespace --force-conflicts --reset-values --wait --timeout 40m $(EXTRA)

.PHONY: undeploy
undeploy:
	KUBECONFIG=$(KUBECONFIG_LAB) helm uninstall poc --namespace poc --wait || true
	KUBECONFIG=$(KUBECONFIG_LAB) kubectl delete namespace poc --wait

.PHONY: phase0-stack
phase0-stack:
	lab/phase0/stack-check.sh
