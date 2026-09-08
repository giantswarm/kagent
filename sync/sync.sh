#!/usr/bin/env bash

# Re-vendor entrypoint. Run it after a version bump in vendir.yml:
#
#   ./sync/sync.sh
#
# It fetches the pristine upstream artifacts into vendor/, flattens the
# controller chart onto helm/kagent and the CRD chart onto helm/kagent-crds,
# re-applies the Giant Swarm delta from sync/patches/, and rewrites diffs/ so
# the review of the bump shows the whole delta from upstream.
#
# Every patch under sync/patches/ is an anchored text replacement that fails
# loudly when upstream reworks the file.

set -o errexit
set -o nounset
set -o pipefail

dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ) ; readonly dir
cd "${dir}/.."

set -x
vendir sync
{ set +x; } 2>/dev/null

# The trailing-whitespace and end-of-file-fixer pre-commit hooks skip only
# helm/*/charts/, so the vendored files at the chart root are normalised here
# and the tree does not flip between two resting formats.
./sync/normalize.py vendor/kagent/templates vendor/kagent/values.yaml vendor/kagent-crds/templates \
	helm/kagent/templates helm/kagent/values.yaml helm/kagent/files helm/kagent-crds/templates sync

./sync/patches/values/patch.sh
./sync/patches/chart-label/patch.sh
./sync/patches/team-label/patch.sh
./sync/patches/chart-yaml/patch.sh
./sync/patches/crds/patch.sh

# The vendor/ half of the checks can only run here, while vendor/ is present.
./sync/verify.sh --with-vendor

# Store the delta from upstream, one patch file per changed file, so a reviewer
# of a version bump reads what we change instead of guessing it. Repo-owned
# files (chart metadata, generated docs and schema, app-owned CRDs) and the
# untouched bundled subcharts are skipped: they have no delta to show. The CRD
# chart is not diffed at all: its templates' only delta is the fixed keep
# annotation and labels include that sync/patches/crds writes (sync/verify.sh
# asserts it file by file against crds/), and its _helpers.tpl and values.yaml
# are repo-owned files with no upstream counterpart.
rm -f ./diffs/*
for chart in kagent ; do
	for f in $(git --no-pager diff --no-exit-code --no-color --no-index "vendor/${chart}" "helm/${chart}" --name-only) ; do
		[[ "$f" == "/dev/null" ]] && continue
		[[ "$f" == "helm/${chart}/Chart.yaml" ]] && continue
		[[ "$f" == "helm/${chart}/README.md" ]] && continue
		[[ "$f" == "helm/${chart}/README.md.gotmpl" ]] && continue
		[[ "$f" == "helm/${chart}/values.schema.json" ]] && continue
		[[ "$f" == "helm/${chart}/.schema.yaml" ]] && continue
		[[ "$f" == "helm/${chart}/.kube-linter.yaml" ]] && continue
		[[ "$f" == "helm/${chart}/zz_generated.app-platform.values.yaml" ]] && continue
		[[ "$f" =~ ^helm/${chart}/crds/.* ]] && continue
		[[ "$f" =~ ^helm/${chart}/charts/.* ]] && continue

		base_file="vendor/${chart}/${f#"helm/${chart}/"}"
		[[ ! -e $base_file ]] && base_file="/dev/null"

		set +e
		git --no-pager diff --no-exit-code --no-color --no-index "$base_file" "${f}" \
			> "./diffs/${f//\//__}.patch" # ${f//\//__} replaces all "/" with "__"
		ret=$?
		set -e
		if [ $ret -ne 0 ] && [ $ret -ne 1 ] ; then
			exit $ret
		fi
	done
done

# Same resting-format reason as the vendor/ normalisation above.
./sync/normalize.py diffs
