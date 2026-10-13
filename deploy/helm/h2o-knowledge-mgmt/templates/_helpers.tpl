{{- define "h2o-knowledge-mgmt.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "h2o-knowledge-mgmt.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "h2o-knowledge-mgmt.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "h2o-knowledge-mgmt.labels" -}}
app.kubernetes.io/name: {{ include "h2o-knowledge-mgmt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "h2o-knowledge-mgmt.storage.fullname" -}}
{{- $storage := index .Values "aws-compatible-storage" -}}
{{- if $storage.fullnameOverride -}}
{{- $storage.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "aws-compatible-storage" $storage.nameOverride -}}
{{- if contains $name $.Release.Name -}}
{{- $.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" $.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "h2o-knowledge-mgmt.storage.secretName" -}}
{{- $s3 := index (index .Values "aws-compatible-storage") "s3" -}}
{{- if $s3.existingSecret -}}
{{- $s3.existingSecret -}}
{{- else -}}
{{- printf "%s-credentials" (include "h2o-knowledge-mgmt.storage.fullname" .) -}}
{{- end -}}
{{- end }}
