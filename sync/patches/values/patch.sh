#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir
script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ) ; readonly script_dir

cd "${repo_dir}"

readonly script_dir_rel=".${script_dir#"${repo_dir}"}"

# values.yaml is repo-owned in full, not merged: it carries the Giant Swarm
# defaults (gsoci registry and flat image repositories, fullnameOverride and
# namespaceOverride, the kagent-tools namespace and image), the pinned global
# image tag with its Renovate marker, and the `# @schema` annotations the
# values.schema.json generator needs. On an upstream bump, read
# diffs/helm__kagent__values.yaml.patch and port any new upstream key into
# this file.
#
# The global `tag` is written here from the vendored version. Every image the
# root chart renders (controller, UI, and the agent runtime tags the controller
# ConfigMap hands out) coalesces `.Values.tag` first and `.Chart.Version` last;
# the chart version is this repo's own, so the fallback would name an image
# that does not exist. The marker line above `tag:` is what Renovate matches.
set -x
vendored=$(yq -r '.directories[] | select(.path == "vendor").contents[] | select(.path == "kagent").helmChart.version' vendir.yml)

python3 - "${script_dir_rel}/values.yaml" "${vendored}" <<'PY'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    content = f.read()

pattern = re.compile(r'^(# renovate: [^\n]*\n)tag: "[^"\n]*"$', re.MULTILINE)
if len(pattern.findall(content)) != 1:
    raise SystemExit(
        f"{path}: expected exactly one `# renovate:` marker followed by a quoted `tag:` line."
    )
new = pattern.sub(lambda m: f'{m.group(1)}tag: "{version}"', content)
if new != content:
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
PY

cp "${script_dir_rel}/values.yaml" ./helm/kagent/values.yaml

{ set +x; } 2>/dev/null
