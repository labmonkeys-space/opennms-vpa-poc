# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

SHELL           := /bin/bash -o nounset -o pipefail -o errexit
.DEFAULT_GOAL   := help
HELM_CHARTS_DIR ?= ../opennms-helm-charts
CHART           := charts/opennms-vpa
BUILD_DIR       := build

.PHONY: help
help:
	@echo "Targets:"
	@echo "  vendor        Link HELM_CHARTS_DIR (feat/vpa-hooks) into vendor/"
	@echo "  deps          Build umbrella dependencies"
	@echo "  lint          helm lint the umbrella"
	@echo "  unittest      helm-unittest suites of the umbrella"
	@echo "  test-scripts  shellcheck and run the shell tests"
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
	@shellcheck -S warning scripts/*.sh $$(ls lab/scripts/*.sh lab/phase0/*.sh 2>/dev/null)

.PHONY: render
render: deps
	@mkdir -p $(BUILD_DIR)
	helm template poc $(CHART) --namespace poc > $(BUILD_DIR)/render.yaml
	kubeconform -strict -ignore-missing-schemas -summary $(BUILD_DIR)/render.yaml

.PHONY: check-public
check-public:
	scripts/check-public.sh

.PHONY: test
test: lint unittest test-scripts render check-public
