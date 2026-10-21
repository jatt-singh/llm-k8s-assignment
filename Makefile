# Thin wrapper over scripts/ci.sh so the same commands work locally and in any CI.
ENV ?= dev
CI  := scripts/ci.sh

.PHONY: help check release plan apply destroy deploy smoke cronjob-check rollback status demo-bad-release demo-blocked demo-hpa demo-alert
help:            ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

check:           ## Lint, unit tests, build, vulnerability scan + gate, SBOM
	$(CI) check
release:         ## check + terraform apply + load images + helm deploy + smoke + cronjob check (main/tags only)
	$(CI) release $(ENV)
plan:            ## terraform plan for ENV
	$(CI) plan $(ENV)
apply:           ## terraform apply for ENV
	$(CI) apply $(ENV)
destroy:         ## terraform destroy for ENV
	$(CI) destroy $(ENV)
deploy:          ## Load images and helm upgrade ENV (no checks)
	$(CI) deploy $(ENV)
smoke:           ## End-to-end test through the TLS ingress, including the LLM
	$(CI) smoke $(ENV)
cronjob-check:   ## Trigger the model-verify CronJob now and assert success
	$(CI) cronjob-check $(ENV)
rollback:        ## helm rollback ENV to the previous revision (REV=n for a specific one)
	$(CI) rollback $(ENV) $(REV)
status:          ## Show what is deployed in ENV
	$(CI) status $(ENV)

demo-blocked:    ## Show a request from a non-allowlisted source being rejected
	scripts/demo/blocked-request.sh $(ENV)
demo-hpa:        ## Generate load on the gateway and watch the HPA scale up
	scripts/demo/hpa-load.sh $(ENV)
demo-bad-release: ## Deploy a broken gateway image, show the stalled rollout, then roll back
	scripts/demo/bad-release.sh $(ENV)
demo-alert:      ## Make the LLM unavailable so GatewayHighErrorRate fires, then restore
	scripts/demo/alert.sh $(ENV)
demo-netpol:     ## Show default-deny NetworkPolicies: only the allowed call-graph edges connect
	scripts/demo/netpol.sh $(ENV)
