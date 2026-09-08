#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_dir=$(git rev-parse --show-toplevel) ; readonly repo_dir

cd "${repo_dir}"

# app-build-suite's C0001 (HasTeamLabel) requires the team label, read from the
# Chart annotation, in templates/_helpers.tpl. Anchored on the exact upstream
# text, so the sync fails loudly if upstream reworks the helper.
set -x
python3 - <<'PY'
path = "helm/kagent/templates/_helpers.tpl"

old = '''app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kagent
{{- with .Values.labels }}'''

new = '''app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kagent
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | quote }}
{{- with .Values.labels }}'''

with open(path, encoding="utf-8") as f:
    content = f.read()

if content.count(new) == 1:
    raise SystemExit(0)

if content.count(old) != 1:
    raise SystemExit(
        f"{path}: the upstream kagent.labels helper is not what this patch "
        "expects. Re-derive the team-label line against the new upstream text."
    )

with open(path, "w", encoding="utf-8") as f:
    f.write(content.replace(old, new))
PY

{ set +x; } 2>/dev/null
