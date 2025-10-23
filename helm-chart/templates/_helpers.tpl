{{/*
Expand the name of the chart.
*/}}
{{- define "akv-sync.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "akv-sync.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "akv-sync.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "akv-sync.labels" -}}
helm.sh/chart: {{ include "akv-sync.chart" . }}
{{ include "akv-sync.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "akv-sync.selectorLabels" -}}
app.kubernetes.io/name: {{ include "akv-sync.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "akv-sync.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "akv-sync.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Build source keyvaults list
*/}}
{{- define "akv-sync.sourceKeyvaults" -}}
{{- if eq .Values.source.selectionMode "specific" }}
{{- range $index, $kv := .Values.source.keyvaults }}
{{- if $index }},{{ end }}{{ $kv.name }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Build source exclusion list
*/}}
{{- define "akv-sync.sourceExcludeKeyvaults" -}}
{{- if eq .Values.source.selectionMode "allExcept" }}
{{- range $index, $kv := .Values.source.excludeKeyvaults }}
{{- if $index }},{{ end }}{{ $kv }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Build secret exclusion list
*/}}
{{- define "akv-sync.excludeSecrets" -}}
{{- range $index, $secret := .Values.sync.excludeSecrets }}
{{- if $index }},{{ end }}{{ $secret }}
{{- end }}
{{- end }}

{{/*
Build destination keyvault names mapping (source:destination)
*/}}
{{- define "akv-sync.destinationKeyvaults" -}}
{{- if eq .Values.source.selectionMode "specific" }}
{{- range $index, $kv := .Values.source.keyvaults }}
{{- if $index }},{{ end }}{{ $kv.name }}:{{ $kv.destinationName | default "" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Build email TO list
*/}}
{{- define "akv-sync.emailTo" -}}
{{- if .Values.notifications.email.enabled }}
{{- join "," .Values.notifications.email.to }}
{{- end }}
{{- end }}
