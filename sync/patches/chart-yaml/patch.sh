#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir

cd "${repo_dir}"

# Both charts keep their own version line (git-replaced at build time), so only
# appVersion tracks upstream. The image tags do NOT read appVersion here (they
# read `tag`, pinned by sync/patches/values); appVersion is metadata.
#
# The dependency list is upstream's: Helm renders every chart under charts/
# whatever Chart.yaml says, but applies a `condition:` only through this list.
# Without it every bundled agent, kmcp, substrate and oauth2-proxy install
# unconditionally. Upstream's repository URLs (`file://../agents/k8s`, OCI
# registries) do not resolve here; app-build-suite runs `helm dependency update`
# before packaging, so every entry points at the vendored copy under charts/.
set -x
app_version=$(yq -r '.directories[] | select(.path == "vendor").contents[] | select(.path == "kagent").helmChart.version' vendir.yml)
crds_version=$(yq -r '.directories[] | select(.path == "vendor").contents[] | select(.path == "kagent-crds").helmChart.version' vendir.yml)

yq -i ".appVersion = \"${app_version}\"" ./helm/kagent/Chart.yaml
yq -i ".appVersion = \"${crds_version}\"" ./helm/kagent-crds/Chart.yaml

yq -i '.dependencies = (load("vendor/kagent/Chart.yaml").dependencies | map({"name": .name, "version": .version, "repository": ("file://charts/" + .name), "condition": .condition}))' ./helm/kagent/Chart.yaml

{ set +x; } 2>/dev/null
