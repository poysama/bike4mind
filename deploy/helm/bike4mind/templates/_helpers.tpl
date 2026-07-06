{{/*
Common labels applied to every object. Service NAMES themselves are fixed to the
compose service names (mongo/minio/sqs/mail/app) so .env.selfhost resolves
unchanged, which means one release per namespace. The release name is carried in
labels for provenance, not in resource names.
*/}}
{{- define "bike4mind.labels" -}}
app.kubernetes.io/part-of: bike4mind
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/*
Per-component selector labels. Pass the component name as the argument.
Usage: {{ include "bike4mind.selectorLabels" "mongo" }}
*/}}
{{- define "bike4mind.selectorLabels" -}}
app: {{ . }}
{{- end -}}
