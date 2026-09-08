#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir

cd "${repo_dir}"

# Two CRD delivery paths ship from the same pristine manifests:
#
#   * helm/kagent/crds/ -- app-owned CRDs. Helm never upgrades a crds/ dir on
#     its own, so consumers apply this chart with Flux `crds: CreateReplace`.
#     The kagent.dev/ and kmcp/ subdirectories separate the two upstream
#     sources.
#   * helm/kagent-crds/templates/ -- the optional Helm-managed lifecycle, for
#     consumers that let Helm own the CRDs and disable the dir above.
#
# Both get helm.sh/resource-policy: keep, so a `helm uninstall` or a Flux prune
# never cascade-deletes every kagent custom resource in the cluster.
#
# The kmcp MCPServer CRD comes from the kmcp-crds subchart bundled in the
# upstream kagent-crds chart, at the kmcp version this kagent release depends
# on. Nothing in the platform enables kmcp, but the controller registers the
# type and the CRD costs one file; dropping it is a separate cleanup.
set -x
mkdir -p ./helm/kagent/crds/kagent.dev ./helm/kagent/crds/kmcp ./helm/kagent-crds/templates
rm -f ./helm/kagent/crds/kagent.dev/*.yaml ./helm/kagent/crds/kmcp/*.yaml
cp ./vendor/kagent-crds/templates/kagent.dev_*.yaml ./helm/kagent/crds/kagent.dev/
cp ./vendor/kagent-crds/charts/kmcp-crds/templates/mcpserver-crd.yaml ./helm/kagent/crds/kmcp/mcpserver-crd.yaml
cp ./vendor/kagent-crds/charts/kmcp-crds/templates/mcpserver-crd.yaml ./helm/kagent-crds/templates/mcpserver-crd.yaml

for f in ./helm/kagent/crds/kagent.dev/*.yaml ./helm/kagent/crds/kmcp/*.yaml ./helm/kagent-crds/templates/kagent.dev_*.yaml ./helm/kagent-crds/templates/mcpserver-crd.yaml ; do
	yq -i '.metadata.annotations."helm.sh/resource-policy" = "keep"' "$f"
done

# The chart's CRDs also carry the Giant Swarm labels. The crds/ dir of the main
# chart cannot: Helm does not template a crds/ dir. The upstream manifests have
# no labels block, so one is added under metadata.
python3 - <<'PY'
import pathlib

OLD = """metadata:
  annotations:
"""

NEW = """metadata:
  labels:
    {{- include "kagent-crds.giantSwarmLabels" . | nindent 4 }}
  annotations:
"""

paths = sorted(pathlib.Path("helm/kagent-crds/templates").glob("kagent.dev_*.yaml"))
paths.append(pathlib.Path("helm/kagent-crds/templates/mcpserver-crd.yaml"))
for path in paths:
    content = path.read_text(encoding="utf-8")
    if content.count(NEW) == 1:
        continue
    if content.count(OLD) != 1:
        raise SystemExit(
            f"{path}: the upstream metadata block is not what this patch expects. "
            "Re-derive the label injection against the new upstream manifests."
        )
    path.write_text(content.replace(OLD, NEW), encoding="utf-8")
PY

{ set +x; } 2>/dev/null
