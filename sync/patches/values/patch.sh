#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir

cd "${repo_dir}"

# values.yaml is generated, not merged and not hand-maintained: generate.py
# applies the Giant Swarm delta to the vendored upstream file as anchored text
# replacements, so a bump carries every new upstream key with its comments and
# fails loudly when upstream moves an anchor. The tag pin comes from vendir.yml
# and the subchart schema annotations from the vendored Chart.yaml, so nothing
# here is typed twice.
set -x
python3 ./sync/patches/values/generate.py \
	./vendor/kagent/values.yaml ./vendor/kagent/Chart.yaml ./vendir.yml ./helm/kagent/values.yaml

{ set +x; } 2>/dev/null
