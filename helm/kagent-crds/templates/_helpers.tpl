{{/*
Giant Swarm labels for the CRDs this chart renders. The upstream manifests carry
no labels block; sync/patches/crds adds one with this include.

The team label is what app-build-suite's Giant Swarm validator (C0001:
HasTeamLabel) looks for in this file.
*/}}
{{- define "kagent-crds.giantSwarmLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ $chart := printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 }}{{ regexReplaceAll "[^a-zA-Z0-9]+$" $chart "" }}
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | quote }}
{{- end -}}
