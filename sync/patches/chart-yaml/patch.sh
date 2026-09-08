#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir

cd "${repo_dir}"

# appVersion tracks upstream; the chart version is this repo's own. Helm
# applies a subchart `condition:` only through the dependency list, so it is
# copied from upstream. Upstream's repository URLs (`file://../agents/k8s`) do
# not resolve here and app-build-suite runs `helm dependency update`, so every
# entry points at the vendored copy under charts/.
set -x
app_version=$(yq -r '.directories[] | select(.path == "vendor").contents[] | select(.path == "kagent").helmChart.version' vendir.yml)
crds_version=$(yq -r '.directories[] | select(.path == "vendor").contents[] | select(.path == "kagent-crds").helmChart.version' vendir.yml)

yq -i ".appVersion = \"${app_version}\"" ./helm/kagent/Chart.yaml
yq -i ".appVersion = \"${crds_version}\"" ./helm/kagent-crds/Chart.yaml

yq -i '.dependencies = (load("vendor/kagent/Chart.yaml").dependencies | map({"name": .name, "version": .version, "repository": ("file://charts/" + .name), "condition": .condition}))' ./helm/kagent/Chart.yaml

{ set +x; } 2>/dev/null
