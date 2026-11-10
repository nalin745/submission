{{/* Chart name */}}
{{- define "auth-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name */}}
{{- define "auth-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "auth-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "auth-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "auth-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "auth-api.labels" -}}
helm.sh/chart: {{ include "auth-api.chart" . }}
{{ include "auth-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Name of the Secret holding DATABASE_URL / REDIS_URL */}}
{{- define "auth-api.secretName" -}}
{{- if .Values.secret.existingSecret }}
{{- .Values.secret.existingSecret }}
{{- else }}
{{- printf "%s-secrets" (include "auth-api.fullname" .) }}
{{- end }}
{{- end }}

{{- define "auth-api.tlsSecretName" -}}
{{- default (printf "%s-tls" (include "auth-api.fullname" .)) .Values.ingress.tls.secretName }}
{{- end }}
