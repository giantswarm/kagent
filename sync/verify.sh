#!/usr/bin/env bash

# Fail when the tree does not match what sync/sync.sh produces. Runs in CI
# without network: it compares files already in the tree and renders the chart.
#
#   ./sync/verify.sh                 the CI gate (vendor/ absent)
#   ./sync/verify.sh --with-vendor   also compare against vendor/ (run by sync.sh)

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir

cd "${repo_dir}"

readonly chart=helm/kagent
readonly crds_chart=helm/kagent-crds

with_vendor=0
[[ "${1:-}" == "--with-vendor" ]] && with_vendor=1

fail=0

note() {
	echo "$1"
	fail=1
}

vendored_version() {
	yq -r ".directories[] | select(.path == \"vendor\").contents[] | select(.path == \"$1\").helmChart.version" vendir.yml
}

# values.yaml is generated from the vendored upstream file by
# sync/patches/values/generate.py. vendor/ is absent in CI, so the Giant Swarm
# defaults it writes are asserted one by one: back at upstream defaults the
# chart would publish with the upstream registry and image paths.
expect() { # expect <yq path> <value>
	local got
	got=$(yq -r "$1" "${chart}/values.yaml")
	[ "${got}" == "$2" ] || note "${chart}/values.yaml has $1 = ${got}, expected $2; run 'make sync'"
}
expect '.registry' 'gsoci.azurecr.io/giantswarm'
expect '.fullnameOverride' 'kagent'
expect '.namespaceOverride' 'kagent'
expect '.controller.image.repository' 'kagent-controller'
expect '.controller.agentImage.repository' 'kagent-app'
expect '.controller.skillsInitImage.repository' 'kagent-skills-init'
expect '.controller.goAgentImage.repository' 'golang-adk'
expect '.ui.image.repository' 'kagent-ui'
expect '."kagent-tools".namespaceOverride' 'kagent'
expect '."kagent-tools".tools.image.registry' 'gsoci.azurecr.io'
expect '."kagent-tools".tools.image.repository' 'giantswarm/kagent-tools'

# The CRD chart is cut from the same upstream tag as the controller chart, so
# the two vendored versions move together.
chart_version=$(vendored_version kagent)
crds_version=$(vendored_version kagent-crds)
if [ "${chart_version}" != "${crds_version}" ] ; then
	note "vendir.yml vendors chart ${chart_version} but CRDs ${crds_version}; the CRDs must track the chart"
fi

for pair in "${chart}:${chart_version}" "${crds_chart}:${crds_version}" ; do
	dir=${pair%:*}
	want=${pair#*:}
	got=$(yq -r '.appVersion' "${dir}/Chart.yaml")
	if [ "${want}" != "${got}" ] ; then
		note "${dir}/Chart.yaml appVersion is ${got} but vendir.yml vendors ${want}; run 'make sync'"
	fi
done

# The global tag selects the controller, UI and agent runtime images. Every
# upstream template coalesces .Values.tag first and .Chart.Version last, and the
# chart version is this repo's own, so an empty or stale pin resolves to an image
# that does not exist.
tag=$(yq -r '.tag' "${chart}/values.yaml")
if [ "${tag}" != "${chart_version}" ] ; then
	note "${chart}/values.yaml pins tag ${tag} but vendir.yml vendors ${chart_version}; run 'make sync'"
fi

# An upstream bump can add a new .Chart.Version fallback that the tag pin does
# not cover. Every such line in a rendered template must also read .Values.tag.
while IFS= read -r line ; do
	echo "${line}" | grep -q '\.Values\.tag' \
		|| note "${line%%:*} reads .Chart.Version without a .Values.tag fallback; extend the tag pin"
done < <(grep -n '\.Chart\.Version' "${chart}"/templates/*.yaml || true)

# The dependency list is what gates the bundled subcharts: Helm renders every
# chart under charts/ but applies a `condition:` only through Chart.yaml.
if yq -e '.dependencies[] | select(.name == "kagent")' "${chart}/Chart.yaml" >/dev/null 2>&1 ; then
	note "${chart}/Chart.yaml still declares the upstream kagent chart as a dependency; the chart is flattened"
fi
for name in $(yq -r '.dependencies[].name' "${chart}/Chart.yaml") ; do
	want=$(yq -r ".dependencies[] | select(.name == \"${name}\").version" "${chart}/Chart.yaml")
	repo=$(yq -r ".dependencies[] | select(.name == \"${name}\").repository" "${chart}/Chart.yaml")
	cond=$(yq -r ".dependencies[] | select(.name == \"${name}\").condition" "${chart}/Chart.yaml")
	[ "${repo}" == "file://charts/${name}" ] || note "${chart}/Chart.yaml dependency ${name} must point at file://charts/${name}"
	[ -n "${cond}" ] && [ "${cond}" != "null" ] || note "${chart}/Chart.yaml dependency ${name} has no condition; run 'make sync'"
	if [ ! -f "${chart}/charts/${name}/Chart.yaml" ] ; then
		note "${chart}/Chart.yaml declares dependency ${name} but ${chart}/charts/${name} is absent; run 'make sync'"
		continue
	fi
	got=$(yq -r '.version' "${chart}/charts/${name}/Chart.yaml")
	# oauth2-proxy is declared as a range upstream; the vendored copy is the one
	# upstream resolved, so only an exact pin is compared.
	if [[ "${want}" =~ ^[0-9] ]] && [ "${want}" != "${got}" ] ; then
		note "${chart}/Chart.yaml pins dependency ${name} ${want} but ${chart}/charts/${name} is ${got}; run 'make sync'"
	fi
done
for dir in "${chart}"/charts/*/ ; do
	name=$(basename "${dir}")
	yq -e ".dependencies[] | select(.name == \"${name}\")" "${chart}/Chart.yaml" >/dev/null 2>&1 \
		|| note "${chart}/charts/${name} has no dependency entry in ${chart}/Chart.yaml, so it renders unconditionally; run 'make sync'"
done
if [ "${with_vendor}" -eq 1 ] ; then
	want=$(yq -o=json '.dependencies | map({"name": .name, "version": .version, "condition": .condition})' vendor/kagent/Chart.yaml)
	got=$(yq -o=json '.dependencies | map({"name": .name, "version": .version, "condition": .condition})' "${chart}/Chart.yaml")
	[ "${want}" == "${got}" ] || note "${chart}/Chart.yaml dependencies drift from vendor/kagent/Chart.yaml; run 'make sync'"
	generated=$(mktemp)
	python3 ./sync/patches/values/generate.py ./vendor/kagent/values.yaml ./vendor/kagent/Chart.yaml ./vendir.yml "${generated}"
	diff -q "${generated}" "${chart}/values.yaml" >/dev/null || note "${chart}/values.yaml is not what sync/patches/values/generate.py writes; run 'make sync'"
	rm -f "${generated}"
fi

# Without the chart-label fix helm-controller's +digest chart version, or a
# branch build's long version, emits an invalid label and the install fails late.
if [ "$(grep -c 'regexReplaceAll "\[^a-zA-Z0-9\]+\$"' "${chart}/templates/_helpers.tpl")" -lt 2 ] ; then
	note "${chart}/templates/_helpers.tpl lost the chart-label fix on helm.sh/chart or app.kubernetes.io/version; run 'make sync'"
fi

# app-build-suite's C0001 validator rejects a chart whose _helpers.tpl carries
# no team label, so a missing line fails the release, not just the label.
for f in "${chart}/templates/_helpers.tpl" "${crds_chart}/templates/_helpers.tpl" ; do
	if ! grep -q 'application.giantswarm.io/team: {{ index .Chart.Annotations' "$f" ; then
		note "$f lost the team label; run 'make sync'"
	fi
done

# Without the keep annotation a helm uninstall or a Flux prune cascade-deletes
# every kagent custom resource in the cluster.
for f in "${chart}"/crds/*/*.yaml ; do
	yq -e '.metadata.annotations."helm.sh/resource-policy" == "keep"' "$f" >/dev/null \
		|| note "$f lost helm.sh/resource-policy: keep; run 'make sync'"
done

# The CRD chart's manifests hold a Helm include, so they are not YAML any more.
for f in "${crds_chart}"/templates/*.yaml ; do
	grep -q 'helm.sh/resource-policy: keep' "$f" \
		|| note "$f lost helm.sh/resource-policy: keep; run 'make sync'"
	grep -q 'include "kagent-crds.giantSwarmLabels"' "$f" \
		|| note "$f lost the Giant Swarm labels include; run 'make sync'"
done

# Both delivery paths must ship the same CRD. The only difference the chart's
# copy is allowed to carry is the labels block with the include.
strip_labels() {
	grep -v -e '^  labels:$' -e 'include "kagent-crds.giantSwarmLabels"' "$1"
}
for f in "${chart}"/crds/kagent.dev/*.yaml ; do
	other="${crds_chart}/templates/$(basename "$f")"
	[ -f "${other}" ] || { note "${other} is missing; run 'make sync'"; continue; }
	if ! strip_labels "${other}" | diff -q - "$f" >/dev/null ; then
		note "$f and ${other} disagree; both ship the same CRD, run 'make sync'"
	fi
done
if ! strip_labels "${crds_chart}/templates/mcpserver-crd.yaml" | diff -q - "${chart}/crds/kmcp/mcpserver-crd.yaml" >/dev/null ; then
	note "${chart}/crds/kmcp/mcpserver-crd.yaml and ${crds_chart}/templates/mcpserver-crd.yaml disagree; run 'make sync'"
fi
for f in "${crds_chart}"/templates/*.yaml ; do
	base=$(basename "$f")
	[ "${base}" == "mcpserver-crd.yaml" ] && continue
	[ -f "${chart}/crds/kagent.dev/${base}" ] || note "${f} has no twin under ${chart}/crds/kagent.dev; run 'make sync'"
done

# The bundled kagent-tools tool server must render into the namespace the
# kagent-tool-server RemoteMCPServer URL names. The upstream chart composes that
# URL from its own namespaceOverride but leaves the subchart in the release
# namespace; values.yaml pins both to `kagent`. The ATS smoke installs into the
# `kagent` namespace, where release namespace and override coincide, so render
# the agent-platform layout here and compare.
if command -v helm >/dev/null 2>&1 ; then
	if tools_render=$(helm template kagent "${chart}" --namespace agent-platform --set kagent-tools.enabled=true 2>&1) ; then
		url=$(echo "${tools_render}" | yq 'select(.kind == "RemoteMCPServer" and .metadata.name == "kagent-tool-server") | .spec.url' | tr -d '"')
		host=${url#*://}; host=${host%%/*}; host=${host%%:*}
		svc_name=${host%%.*}
		svc_ns=${host#*.}; svc_ns=${svc_ns%%.*}
		[ -n "${url}" ] && [ "${url}" != "null" ] || note "no kagent-tool-server RemoteMCPServer url rendered"
		for kind in Service Deployment ServiceAccount ; do
			got=$(echo "${tools_render}" | yq "select(.kind == \"${kind}\" and .metadata.name == \"${svc_name}\") | .metadata.namespace" | tr -d '"')
			[ "${got}" == "${svc_ns}" ] \
				|| note "kagent-tools ${kind} renders into namespace '${got}' but the RemoteMCPServer url ${url} names '${svc_ns}'; keep kagent-tools.namespaceOverride equal to namespaceOverride in values.yaml"
		done
	else
		note "helm template of ${chart} failed: ${tools_render}"
	fi
else
	echo "helm not found; skipping the kagent-tools namespace render check"
fi

exit "${fail}"
