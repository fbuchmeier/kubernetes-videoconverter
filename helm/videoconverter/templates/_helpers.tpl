{{- define "videoconverter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "videoconverter.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" (include "videoconverter.name" .) -}}
{{- end -}}
{{- end -}}

{{- define "videoconverter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "videoconverter.labels" -}}
helm.sh/chart: {{ include "videoconverter.chart" . }}
app.kubernetes.io/name: {{ include "videoconverter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "videoconverter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "videoconverter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "videoconverter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "videoconverter.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
