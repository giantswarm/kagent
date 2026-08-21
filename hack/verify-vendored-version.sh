#!/usr/bin/env bash
# Verify that every place the upstream kagent version is written agrees with the
# pin in vendir.yml.
#
# `helm lint`, `helm template` and `helm package` all pass when the version
# strings and the vendored tree disagree, so a dependency bump that edits
# vendir.yml without re-running `make sync` would otherwise ship a chart that
# claims one upstream release and contains another. This check is that gate.
#
# Reads with path expressions understood by both mikefarah yq and python-yq, and
# strips quotes so either flavour compares equal.
set -euo pipefail

YQ=${YQ:-yq}
cd "$(dirname "$0")/.."

y() { $YQ "$1" "$2" | tr -d '"'; }

pin=$(y '.directories[] | select(.path == "helm/kagent/charts/kagent") | .contents[0].helmChart.version' vendir.yml)
[[ -n $pin && $pin != null ]] || { echo "FAIL: no kagent helmChart version found in vendir.yml"; exit 1; }
echo "vendir.yml pins upstream kagent $pin"

rc=0
check() { # check <what> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    printf '  ok    %-42s %s\n' "$1" "$3"
  else
    printf '  FAIL  %-42s %s (want %s)\n' "$1" "${3:-<missing>}" "$2"
    rc=1
  fi
}

check "vendir.lock.yml pin" "$pin" \
  "$(y '.directories[] | select(.path == "helm/kagent/charts/kagent") | .contents[0].helmChart.version' vendir.lock.yml)"
check "vendored subchart Chart.yaml version" "$pin" \
  "$(y '.version' helm/kagent/charts/kagent/Chart.yaml)"
check "helm/kagent/Chart.yaml appVersion" "$pin" \
  "$(y '.appVersion' helm/kagent/Chart.yaml)"
check "helm/kagent/Chart.yaml kagent dependency" "$pin" \
  "$(y '.dependencies[] | select(.name == "kagent") | .version' helm/kagent/Chart.yaml)"
check "helm/kagent/Chart.lock kagent dependency" "$pin" \
  "$(y '.dependencies[] | select(.name == "kagent") | .version' helm/kagent/Chart.lock)"
# The CRDs are vendored from the git tag of the same upstream release.
check "vendir.yml kagent.dev CRD git ref" "v$pin" \
  "$(y '.directories[] | select(.path == "helm/kagent/crds") | .contents[] | select(.path == "kagent.dev") | .git.ref' vendir.yml)"
check "vendir.lock.yml kagent.dev CRD git tag" "v$pin" \
  "$(y '.directories[] | select(.path == "helm/kagent/crds") | .contents[] | select(.path == "kagent.dev") | .git.tags[0]' vendir.lock.yml)"

if [[ $rc -ne 0 ]]; then
  echo
  echo "Upstream kagent version is inconsistent. Run 'make sync' (needs vendir, yq and"
  echo "helm on PATH), then commit the result including the regenerated README."
fi
exit $rc
