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
# Every patch under sync/patches/ is either an anchored text replacement that
# fails loudly when upstream reworks the file, or a copy of a repo-owned file.
# Nothing here edits a vendored file in place with line-addressed sed.

set -o errexit
set -o nounset
set -o pipefail

dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ) ; readonly dir
cd "${dir}/.."

set -x
vendir sync
{ set +x; } 2>/dev/null

# Trailing whitespace and a missing final newline in a vendored file would be
# rewritten by the trailing-whitespace / end-of-file-fixer pre-commit hooks,
# which do not skip the chart root (only helm/*/charts/). Normalise here so the
# hooks are a no-op and the tree does not flip between two resting formats.
# This runs before the patches, so the repo-owned values.yaml and the copy of it
# in the chart stay byte-identical (`make verify-sync` compares them). The
# bundled subcharts under helm/kagent/charts/ are left as upstream ships them.
./sync/normalize.py vendor/kagent/templates vendor/kagent/values.yaml vendor/kagent-crds/templates \
	helm/kagent/templates helm/kagent/values.yaml helm/kagent/files helm/kagent-crds/templates sync

./sync/patches/values/patch.sh
./sync/patches/chart-label/patch.sh
./sync/patches/team-label/patch.sh
./sync/patches/chart-yaml/patch.sh
./sync/patches/crds/patch.sh

# The dependency list is the only part of the repo-owned Chart.yaml that comes
# from upstream, and it is what gates the bundled subcharts. Check it right
# after the patch, while vendor/ is present.
./sync/verify.sh --with-vendor

# Store the delta from upstream, one patch file per changed file, so a reviewer
# of a version bump reads what we change instead of guessing it. Repo-owned
# files (chart metadata, generated docs and schema, app-owned CRDs) and the
# untouched bundled subcharts are skipped: they have no delta to show. The CRD
# chart's templates are skipped too: their only delta is the fixed keep
# annotation and labels include that sync/patches/crds writes, and
# sync/verify.sh asserts it file by file against crds/.
rm -f ./diffs/*
for chart in kagent kagent-crds ; do
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
		[[ "$chart" == "kagent-crds" && "$f" =~ ^helm/${chart}/templates/.*\.yaml$ ]] && continue

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
