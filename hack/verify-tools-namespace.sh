#!/usr/bin/env bash
# Verify that the bundled kagent-tools tool server renders into the namespace
# the kagent-tool-server RemoteMCPServer URL names.
#
# The upstream chart composes that URL from its own namespaceOverride
# (charts/kagent/templates/toolserver-kagent.yaml renders
# `http://<tools fullname>.<kagent namespace>:8084/mcp`) but leaves the
# kagent-tools subchart's namespace at the subchart's own namespaceOverride,
# which defaults to the release namespace. helm/kagent/values.yaml pins both to
# `kagent`; nothing upstream keeps them equal, `helm lint` and `helm template`
# pass when they drift, and the ATS smoke cannot see it either: ATS installs
# into the `kagent` namespace, where release namespace and override coincide.
# So render the layout the agent-platform meta-package deploys -- release
# namespace `agent-platform`, kagent core in `kagent` -- and compare. A mismatch
# is a RemoteMCPServer that never becomes Accepted ("no such host") and agents
# without their built-in tools.
#
# Reads with path expressions understood by both mikefarah yq and python-yq, and
# strips quotes so either flavour compares equal.
set -euo pipefail

YQ=${YQ:-yq}
RELEASE_NAMESPACE=${RELEASE_NAMESPACE:-agent-platform}
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

y() { $YQ "$1" "$2" | tr -d '"'; }

render() { # render <out> <template>...
  local out=$1; shift
  local args=()
  for t in "$@"; do args+=(--show-only "$t"); done
  helm template kagent helm/kagent --namespace "$RELEASE_NAMESPACE" \
    --set kagent.kagent-tools.enabled=true "${args[@]}" >"$out"
}

render "$tmp/toolserver.yaml" charts/kagent/templates/toolserver-kagent.yaml
render "$tmp/tools.yaml" \
  charts/kagent/charts/kagent-tools/templates/deployment.yaml \
  charts/kagent/charts/kagent-tools/templates/service.yaml \
  charts/kagent/charts/kagent-tools/templates/serviceaccount.yaml \
  charts/kagent/charts/kagent-tools/templates/clusterrolebinding.yaml

url=$(y 'select(.kind == "RemoteMCPServer") | .spec.url' "$tmp/toolserver.yaml")
[[ -n $url && $url != null ]] || { echo "FAIL: no RemoteMCPServer url rendered from toolserver-kagent.yaml"; exit 1; }
host=${url#*://}; host=${host%%/*}; host=${host%%:*}
svc_name=${host%%.*}
svc_ns=${host#*.}; svc_ns=${svc_ns%%.*}
[[ $svc_ns != "$host" ]] || { echo "FAIL: RemoteMCPServer url $url does not name a <service>.<namespace> host"; exit 1; }
echo "RemoteMCPServer kagent-tool-server url $url -> Service $svc_ns/$svc_name (release namespace $RELEASE_NAMESPACE)"

rc=0
check() { # check <what> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    printf '  ok    %-42s %s\n' "$1" "$3"
  else
    printf '  FAIL  %-42s %s (want %s)\n' "$1" "${3:-<missing>}" "$2"
    rc=1
  fi
}

check "kagent-tools Service namespace" "$svc_ns" \
  "$(y "select(.kind == \"Service\" and .metadata.name == \"$svc_name\") | .metadata.namespace" "$tmp/tools.yaml")"
check "kagent-tools Deployment namespace" "$svc_ns" \
  "$(y "select(.kind == \"Deployment\" and .metadata.name == \"$svc_name\") | .metadata.namespace" "$tmp/tools.yaml")"
check "kagent-tools ServiceAccount namespace" "$svc_ns" \
  "$(y "select(.kind == \"ServiceAccount\" and .metadata.name == \"$svc_name\") | .metadata.namespace" "$tmp/tools.yaml")"
check "kagent-tools ClusterRoleBinding subject ns" "$svc_ns" \
  "$(y 'select(.kind == "ClusterRoleBinding") | .subjects[0].namespace' "$tmp/tools.yaml")"

if [[ $rc -ne 0 ]]; then
  echo "FAIL: the kagent-tools subchart renders into a different namespace than the RemoteMCPServer URL names."
  echo "      Keep kagent.kagent-tools.namespaceOverride equal to kagent.namespaceOverride in helm/kagent/values.yaml."
fi
exit $rc
