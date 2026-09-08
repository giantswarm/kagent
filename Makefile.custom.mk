##@ Vendoring

# Consumed by the generated App targets (Makefile.gen.app.mk) so they resolve
# helm/kagent/... without an explicit APPLICATION= on the command line. A
# command-line override still wins.
APPLICATION := kagent

# The upstream chart is flattened onto the chart root by vendir and the Giant
# Swarm delta is re-applied by sync/sync.sh, so re-vendoring is that script and
# not `helm dependency update`. Override the generated update-chart/update-deps
# entrypoints (the bundled subcharts are vendored, not resolved) so a habitual
# `make update-chart` does the right thing.
.PHONY: sync
sync: ## Re-vendor upstream and re-apply the Giant Swarm delta (see sync/sync.sh).
	./sync/sync.sh

update-chart: sync
update-deps: sync

.PHONY: verify-sync
verify-sync: ## Fail when the tree does not match what sync/sync.sh produces.
	./sync/verify.sh
