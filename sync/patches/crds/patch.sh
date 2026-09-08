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
#
# The edits are anchored text insertions, not `yq -i`: yq re-emits the whole
# file in its own sequence indentation, which turns a three-line delta into a
# full-file rewrite and makes an upstream bump unreviewable.
set -x
mkdir -p ./helm/kagent/crds/kagent.dev ./helm/kagent/crds/kmcp ./helm/kagent-crds/templates
rm -f ./helm/kagent/crds/kagent.dev/*.yaml ./helm/kagent/crds/kmcp/*.yaml
cp ./vendor/kagent-crds/templates/kagent.dev_*.yaml ./helm/kagent/crds/kagent.dev/
cp ./vendor/kagent-crds/charts/kmcp-crds/templates/mcpserver-crd.yaml ./helm/kagent/crds/kmcp/mcpserver-crd.yaml
cp ./vendor/kagent-crds/charts/kmcp-crds/templates/mcpserver-crd.yaml ./helm/kagent-crds/templates/mcpserver-crd.yaml

python3 - <<'PY'
import pathlib
import re

# Every upstream CRD starts its metadata with the controller-gen annotation and
# has no labels block. The regex asserts that shape (one match per file) so the
# sync fails loudly if upstream changes it.
HEAD = re.compile(
    r"^metadata:\n  annotations:\n(    controller-gen\.kubebuilder\.io/version: \S+\n)",
    re.MULTILINE,
)
KEEP = "    helm.sh/resource-policy: keep\n"
LABELS = '  labels:\n    {{- include "kagent-crds.giantSwarmLabels" . | nindent 4 }}\n'


def edit(path: pathlib.Path, with_labels: bool) -> None:
    content = path.read_text(encoding="utf-8")
    if KEEP in content and (LABELS in content) == with_labels:
        return
    if len(HEAD.findall(content)) != 1:
        raise SystemExit(
            f"{path}: the upstream metadata block is not what this patch expects. "
            "Re-derive the keep/labels injection against the new upstream manifests."
        )
    labels = LABELS if with_labels else ""
    content = HEAD.sub(lambda m: f"metadata:\n{labels}  annotations:\n{m.group(1)}{KEEP}", content, count=1)
    path.write_text(content, encoding="utf-8")


for path in sorted(pathlib.Path("helm/kagent/crds").glob("*/*.yaml")):
    edit(path, with_labels=False)
for path in sorted(pathlib.Path("helm/kagent-crds/templates").glob("*.yaml")):
    edit(path, with_labels=True)
PY

{ set +x; } 2>/dev/null
