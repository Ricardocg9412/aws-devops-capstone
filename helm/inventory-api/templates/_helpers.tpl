{{/* Release-aware names and stable selectors. */}}
{{- define "inventory-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "inventory-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "inventory-api.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- define "inventory-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "inventory-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "inventory-api.labels" -}}
{{- $base := dict "helm.sh/chart" (printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_") "app.kubernetes.io/name" (include "inventory-api.name" .) "app.kubernetes.io/instance" .Release.Name "app.kubernetes.io/version" .Chart.AppVersion "app.kubernetes.io/managed-by" .Release.Service -}}
{{- mergeOverwrite (deepCopy .Values.commonLabels) $base | toYaml -}}
{{- end -}}
{{- define "inventory-api.podLabels" -}}
{{- $labels := mergeOverwrite (include "inventory-api.labels" . | fromYaml) (deepCopy .Values.podLabels) (include "inventory-api.selectorLabels" . | fromYaml) -}}
{{- $labels | toYaml -}}
{{- end -}}
{{- define "inventory-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "inventory-api.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
{{- define "inventory-api.configMapName" -}}
{{- printf "%s-config" (include "inventory-api.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{/* Reject combinations that JSON Schema cannot compare across fields. */}}
{{- define "inventory-api.validate" -}}
{{- range $section := list "requests" "limits" -}}
{{- range $resource := list "cpu" "memory" -}}
{{- $quantity := index (index $.Values.resources $section) $resource -}}
{{- if le (float64 (regexFind "^[0-9]+[.]?[0-9]*" $quantity)) 0.0 -}}
{{- fail (printf "resources.%s.%s must be positive" $section $resource) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if .Values.autoscaling.enabled -}}
{{- if ne .Values.replicaCount nil -}}
{{- fail "autoscaling.enabled=true requires replicaCount=null; HPA must own replicas" -}}
{{- end -}}
{{- if gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas) -}}
{{- fail "autoscaling.minReplicas must be <= maxReplicas" -}}
{{- end -}}
{{- $cpu := dig "requests" "cpu" "" .Values.resources -}}
{{- if or (not $cpu) (le (float64 (trimSuffix "m" $cpu)) 0.0) -}}
{{- fail "CPU-based HPA requires a positive resources.requests.cpu" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.ingress.enabled .Values.httpRoute.enabled -}}
{{- fail "Enable only one of ingress or httpRoute" -}}
{{- end -}}
{{- range $key := list "UVICORN_PORT" "UVICORN_HOST" "TMPDIR" "PYTHONDONTWRITEBYTECODE" -}}
{{- if hasKey $.Values.config $key -}}
{{- fail (printf "config.%s is chart-managed; configure containerPort for the port" $key) -}}
{{- end -}}
{{- end -}}
{{- range $labels := list .Values.commonLabels .Values.podLabels -}}
{{- range $key := list "app.kubernetes.io/name" "app.kubernetes.io/instance" -}}
{{- if hasKey $labels $key -}}
{{- fail (printf "Label %s is reserved for stable release selectors" $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
