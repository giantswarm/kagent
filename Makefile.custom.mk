##@ Vendoring

# CRD source files vendored under helm/kagent/crds (kagent.dev + kmcp MCPServer).
# Unlike agent-sandbox (which injects keep at render time from a pristine
# files/crds), these ship in the literal crds/ dir for the app-owned-CRDs pattern
# (Flux `crds: CreateReplace`), so the keep annotation must be baked into the
# committed files. `vendir sync` overwrites them pristine, so re-inject afterwards.
# A bump that runs `vendir sync` on its own -- which is what the Renovate vendir
# manager does -- drops the annotation, so `make verify` gates it.
YQ ?= yq

.PHONY: sync
sync: ## Re-vendor the upstream kagent chart + CRDs (pinned in vendir.yml), re-inject the keep annotation and propagate the version.
	vendir sync
	@echo "Injecting helm.sh/resource-policy: keep into vendored CRDs..."
	./hack/crd-keep.sh
	@echo "Synced upstream chart (helm/kagent/charts/kagent) and CRDs (helm/kagent/crds) with keep injected."
	@$(MAKE) --no-print-directory propagate-version
	@$(MAKE) --no-print-directory verify
	@echo "Run 'make sync' with mikefarah yq v4 on PATH (set YQ=... to override)."

# The upstream version is typed in exactly one place -- the vendir.yml pin, which
# is what Renovate edits. `sync` propagates it into the chart metadata so no
# second string has to be bumped by hand, and `verify-version` is the CI gate for
# a bump that never ran `sync`.
KAGENT_VERSION = $(shell $(YQ) '.directories[] | select(.path == "helm/kagent/charts/kagent") | .contents[0].helmChart.version' vendir.yml | tr -d '"')

.PHONY: verify
verify: verify-version verify-crd-keep ## Run every check on the vendored tree.

.PHONY: verify-version
verify-version: ## Check that every kagent version string agrees with the vendir.yml pin.
	./hack/verify-vendored-version.sh

.PHONY: verify-crd-keep
verify-crd-keep: ## Check that every vendored CRD carries helm.sh/resource-policy: keep.
	./hack/crd-keep.sh --check

.PHONY: propagate-version
propagate-version: ## Write the vendir.yml pin into the umbrella chart metadata.
	@echo "Propagating upstream kagent $(KAGENT_VERSION) into helm/kagent/Chart.yaml..."
	@sed -i -E 's/^appVersion: .*/appVersion: $(KAGENT_VERSION)/' helm/kagent/Chart.yaml
	@sed -i -E 's/^    version: .*/    version: $(KAGENT_VERSION)/' helm/kagent/Chart.yaml
	helm dependency update helm/kagent
