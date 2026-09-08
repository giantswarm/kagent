#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir

cd "${repo_dir}"

# Both version labels now carry OUR chart version, not the upstream one.
# helm-controller renders a chart pulled from an OCIRepository with the digest
# appended (`0.2.0+abc123`), and `+` is not valid in a label value; upstream
# sanitises it on `helm.sh/chart` but not on `app.kubernetes.io/version`, so
# the install would fail at apply time. In a branch build the version is also a
# long git-replaced string, and upstream's `trunc 63 | trimSuffix "-"` can cut
# inside a separator and emit a label that ends in a non-alphanumeric, which
# Kubernetes rejects. Strip every trailing non-alphanumeric on both.
#
# The replacement asserts on the exact upstream text, so the sync fails loudly
# if upstream reworks the helper and the fix can never be lost silently. It is
# done in python rather than as a stored .patch because the repo's
# trailing-whitespace pre-commit hook rewrites .patch files.
set -x
python3 - <<'PY'
path = "helm/kagent/templates/_helpers.tpl"

old = '''{{- define "kagent.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "kagent.selectorLabels" . }}
{{- if .Chart.Version }}
app.kubernetes.io/version: {{ .Chart.Version | quote }}
{{- end }}'''

new = '''{{- define "kagent.labels" -}}
{{- $chart := printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 -}}
helm.sh/chart: {{ regexReplaceAll "[^a-zA-Z0-9]+$" $chart "" }}
{{ include "kagent.selectorLabels" . }}
{{- if .Chart.Version }}
{{- $version := .Chart.Version | replace "+" "_" | trunc 63 }}
app.kubernetes.io/version: {{ regexReplaceAll "[^a-zA-Z0-9]+$" $version "" | quote }}
{{- end }}'''

with open(path, encoding="utf-8") as f:
    content = f.read()

if content.count(new) == 1:
    raise SystemExit(0)

if content.count(old) != 1:
    raise SystemExit(
        f"{path}: the upstream kagent.labels helper is not what this patch "
        "expects. Re-derive the chart-label fix against the new upstream text."
    )

with open(path, "w", encoding="utf-8") as f:
    f.write(content.replace(old, new))
PY

{ set +x; } 2>/dev/null
