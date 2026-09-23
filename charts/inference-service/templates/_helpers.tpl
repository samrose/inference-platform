{{- define "inference-service.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "inference-service.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "inference-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "inference-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "inference-service.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "inference-service.selectorLabels" . }}
{{- end }}

{{/* repository@sha256:... — a tag is refused so a deploy is always reproducible */}}
{{- define "inference-service.image" -}}
{{- if .Values.image.tag -}}
{{- fail "image.tag is not supported: set image.digest (sha256:...) instead" -}}
{{- end -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $digest := required "image.digest is required (sha256:...)" .Values.image.digest -}}
{{- if not (hasPrefix "sha256:" $digest) -}}
{{- fail (printf "image.digest must start with sha256: (got %q)" $digest) -}}
{{- end -}}
{{- printf "%s@%s" $repo $digest -}}
{{- end }}

{{/* ceil(loadTimeoutSeconds / periodSeconds), at least 1 */}}
{{- define "inference-service.startupFailureThreshold" -}}
{{- $n := divf (.Values.engine.loadTimeoutSeconds | float64) (.Values.probes.periodSeconds | float64) | ceil | int -}}
{{- max $n 1 -}}
{{- end }}
