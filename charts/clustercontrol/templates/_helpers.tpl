{{/*
Expand the name of the chart.
*/}}
{{- define "cc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cc.fullname" -}}
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
{{- define "cc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cc.labels" -}}
helm.sh/chart: {{ include "cc.chart" . }}
{{ include "cc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cc.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cc.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
CMON image selection - use devImage if devBuild is true, otherwise use regular image
*/}}
{{- define "cc.cmonImage" -}}
{{- if .Values.devBuild }}
{{- .Values.cmon.devImage | required ".Values.cmon.devImage is missing when devBuild is enabled" }}
{{- else }}
{{- .Values.cmon.image | required ".Values.cmon.image is missing" }}
{{- end }}
{{- end }}

{{/*
CMON SD image selection - use devImage if devBuild is true, otherwise use regular image
*/}}
{{- define "cc.cmonSdImage" -}}
{{- if .Values.devBuild }}
{{- .Values.cmon.sd.devImage | required ".Values.cmon.sd.devImage is missing when devBuild is enabled" }}
{{- else }}
{{- .Values.cmon.sd.image | required ".Values.cmon.sd.image is missing" }}
{{- end }}
{{- end }}

{{/*
CMON Exporter image selection - use devImage if devBuild is true, otherwise use regular image
*/}}
{{- define "cc.cmonExporterImage" -}}
{{- if .Values.devBuild }}
{{- .Values.cmon.exporter.devImage | required ".Values.cmon.exporter.devImage is missing when devBuild is enabled" }}
{{- else }}
{{- .Values.cmon.exporter.image | required ".Values.cmon.exporter.image is missing" }}
{{- end }}
{{- end }}


{{/*
CCMGR image selection - use devImage if devBuild is true, otherwise use regular image
*/}}
{{- define "cc.ccmgrImage" -}}
{{- if .Values.devBuild }}
{{- .Values.cmon.ccmgr.devImage | required ".Values.cmon.ccmgr.devImage is missing when devBuild is enabled" }}
{{- else }}
{{- .Values.cmon.ccmgr.image | required ".Values.cmon.ccmgr.image is missing" }}
{{- end }}
{{- end }}

{{/*
Kuber Proxy image selection - use devImage if devBuild is true, otherwise use regular image
*/}}
{{- define "cc.kuberProxyImage" -}}
{{- if .Values.devBuild }}
{{- .Values.cmon.kuberProxy.devImage | required ".Values.cmon.kuberProxy.devImage is missing when devBuild is enabled" }}
{{- else }}
{{- .Values.cmon.kuberProxy.image | required ".Values.cmon.kuberProxy.image is missing" }}
{{- end }}
{{- end }}