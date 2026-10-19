# The whole run, in the order CI runs it. `close` needs Linux (the host's
# iptables), and the bundle GNU tar and coreutils; the steps before them run
# anywhere Docker does.
SHELL := /usr/bin/env bash
CLUSTER ?= air-gapped
MODEL ?= granite-4.0-1b
export MODEL
BIN := $(shell ./scripts/install-tools.sh)
export PATH := $(BIN):$(PATH)

.PHONY: help tools check up test evals down

help:
	@echo "make check    the static checks, and each shown its planted violation"
	@echo "make up       stage everything outside, carry it in as one signed file, close, install inside, the gateway last"
	@echo "make test     prove the boundary and the model's way in"
	@echo "make evals    run the agent through the evals, by way of the gateway, and judge the run"
	@echo "make down     delete the cluster and undo the boundary on this host"

tools:
	@echo "tools in $(BIN)"

check:
	./scripts/validate.sh
	python3 tests/static/plant_violations.py

up:
	kind get clusters 2>/dev/null | grep -qx $(CLUSTER) || kind create cluster --config kind/cluster.yaml --wait 120s
	./scripts/airgap.sh registry
	./scripts/airgap.sh seed
	./scripts/airgap.sh mirror
	./scripts/model.sh build
	./scripts/model.sh sign
	./scripts/model.sh plants
	./scripts/admission.sh fetch
	./scripts/gateway.sh fetch
	./scripts/bundle.sh create
	./scripts/airgap.sh registry
	rm -rf .cache/airgap/charts
	./scripts/airgap.sh mirror
	./scripts/airgap.sh close
	./scripts/bundle.sh load
	./scripts/admission.sh install
	./scripts/admission.sh policy
	./scripts/serve.sh
	./scripts/tools.sh
	./scripts/gateway.sh install

test:
	./tests/e2e/run.sh

evals:
	./scripts/evals.sh

down:
	kind delete cluster --name $(CLUSTER)
	./scripts/airgap.sh open
