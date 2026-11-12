{{/* Name of the broker's NATS objects (the Service is "nats", the schema pins it). */}}
{{- define "broker.natsName" -}}
{{- .Values.nats.fullnameOverride | default "nats" -}}
{{- end -}}

{{/* Labels that select the Pods of the NATS server (set by the NATS chart; checked against its render). */}}
{{- define "broker.natsSelectorLabels" -}}
app.kubernetes.io/name: nats
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: nats
{{- end -}}

{{/* Labels on the objects of this chart (the NetworkPolicy and the smoke test). */}}
{{- define "broker.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
