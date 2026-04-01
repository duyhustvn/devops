{{/*
Create the name of the chart dify.name
If nameOverride is defined, use nameOverride
else use Chart.Name
Truncate to 63 chars and trim suffix "-" (DNS limit)

Example: helm upgrade --install my-release ./helm -f values-devlocal.yaml
+ Release.Name = my-release (argument đầu tiên sau --install)
+ Chart.Name = dify (name defined in Chart.yaml field: name)

-> dify.name = dify

*/}}
{{- define "dify.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this 
(by the DNS naming spec).
If release name contains chart name it will be used as a full name.

Example: helm upgrade --install my-release ./helm -f values-devlocal.yaml
+ Release.Name = my-release (argument đầu tiên sau --install)
+ Chart.Name = dify (name defined in Chart.yaml field: name)

-> dify.fullname = my-release-dify
*/}}
{{- define "dify.fullname" -}}
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
Example: helm upgrade --install my-release ./helm -f values-devlocal.yaml
+ Release.Name = my-release (argument đầu tiên sau --install)
+ Chart.Name = dify (name defined in Chart.yaml field: name)
+ Chart.Version = 1.0.0 (version defined in Chart.yaml field: version)

-> dify.chart = dify-1.0.0
*/}}
{{- define "dify.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "dify.labels" -}}
helm.sh/chart: {{ include "dify.chart" . }}
{{ include "dify.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "dify.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dify.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Global labels
*/}}
{{- define "dify.global.labels" -}}
{{- if .Values.global.labels }}
{{- toYaml .Values.global.labels }}
{{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "dify.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dify.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "dify.baseUrl" -}}
{{ if .Values.global.enableTLS }}https://{{ else }}http://{{ end }}{{.Values.global.host}}{{ if .Values.global.port }}:{{.Values.global.port}}{{ end }}
{{- end }}

{{/*
dify environments
commonEnvs are for all containers
commonBackendEnvs are for api and worker containers
*/}}
{{- define "dify.commonEnvs" -}}
- name: EDITION
  value: {{ .Values.global.edition }}
{{- range tuple "CONSOLE_API_URL" "CONSOLE_WEB_URL" "SERVICE_API_URL" "APP_API_URL" "APP_WEB_URL" }}
- name: {{ . }}
  value: {{ include "dify.baseUrl" $ }}
{{- end }}
- name: ENDPOINT_URL_TEMPLATE
  value: {{ include "dify.baseUrl" $ }}.{{ .Values.global.namespace }}.svc.cluster.local/e/{hook_id}
{{- end }}


{{- define "dify.commonBackendEnvs" -}}
- name: STORAGE_TYPE
  value: {{ .Values.global.storageType }}

{{- if .Values.proxy.enabled }}
- name: HTTP_PROXY
  value: "{{ .Values.proxy.proxy }}"
- name: HTTPS_PROXY
  value: "{{ .Values.proxy.proxy }}"
- name: NO_PROXY
  value: "localhost,127.0.0.1,::1,10.42.0.0/16,10.43.0.0/16,svc.cluster.local,cluster.local"

{{- if .Values.proxy.ca_crt.enabled }}
- name: REQUESTS_CA_BUNDLE
  value: "/etc/ssl/certs/ca-certificates.crt"
- name: SSL_CERT_FILE
  value: "/etc/ssl/certs/ca-certificates.crt"
{{- end }}
{{- end }}


- name: REDIS_USE_SENTINEL
  value: "true"
- name: REDIS_SENTINELS
  value: "redis-headless.redis.svc.cluster.local:26379"
- name: REDIS_SENTINEL_SERVICE_NAME
  value: "redis-master"
- name: CELERY_USE_SENTINEL
  value: "true"
- name: CELERY_SENTINEL_MASTER_NAME
  value: "redis-master"
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: redis-secret
      key: redis-password
- name: REDIS_PORT
  value: "26379"

- name: CELERY_BROKER_URL
  value: "sentinel://:$(REDIS_PASSWORD)@redis-headless.redis.svc.cluster.local:26379/1"

- name: DB_USERNAME
  valueFrom:
    configMapKeyRef:
      name: postgresql-config
      key: POSTGRES_USER 
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgresql-secret
      key: POSTGRES_PASSWORD 
- name: DB_HOST
  valueFrom:
    configMapKeyRef:
      name: postgresql-config
      key: POSTGRES_HOST 
- name: DB_PORT
  valueFrom:
    configMapKeyRef:
      name: postgresql-config
      key: POSTGRES_PORT

{{- if .Values.vector_store.enabled }}
- name: VECTOR_STORE 
  value: "{{ .Values.vector_store.type }}"
- name: WEAVIATE_ENDPOINT
  value: "192.168.56.141:8080"
- name: WEAVIATE_API_KEY
  value: "WVF5YThaHlkYwhGUSmCRgsX3tD5ngdN8pkih"
{{- end }}

{{- if eq .Values.global.storageType "s3" }}
- name: S3_HOST
  value: minio-headless.minio.svc.cluster.local
- name: S3_PORT
  value: "9000"
- name: S3_ENDPOINT
  value: http://$(S3_HOST):$(S3_PORT) # k8s will replace at runtime
- name: S3_BUCKET_NAME
  value: dify
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: minio-secret
      key: root-user
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: minio-secret
      key: root-password

# Env for plugin daemon
- name: PLUGIN_STORAGE_TYPE
  value: "aws_s3"
- name: S3_USE_AWS
  value: "false"
- name: S3_USE_AWS_MANAGED_IAM
  value: "false"
- name: PLUGIN_STORAGE_OSS_BUCKET
  value: dify-plugin
- name: S3_USE_PATH_STYLE
  value: "true"
- name: AWS_REGION
  value: "us-east-1"
- name: AWS_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: minio-secret
      key: root-user
- name: AWS_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: minio-secret
      key: root-password
{{- end }}

{{- if .Values.pluginDaemon.enabled }}
- name: PLUGIN_DAEMON_URL
  value: "http://{{ include "dify.fullname" . }}-plugin-daemon.{{ .Values.global.namespace }}.svc.cluster.local:{{ .Values.pluginDaemon.service.port }}"
- name: MARKETPLACE_API_URL
  value: 'https://marketplace.dify.ai'

- name: PLUGIN_DAEMON_KEY
{{- if .Values.pluginDaemon.serverKeySecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pluginDaemon.serverKeySecret }}
      key: plugin-daemon-key
{{- else if .Values.pluginDaemon.serverKey }}
  value: {{ .Values.pluginDaemon.serverKey | quote }}
{{- else }}
{{- end }}

- name: PLUGIN_DIFY_INNER_API_KEY
{{- if .Values.pluginDaemon.difyInnerApiKeySecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pluginDaemon.difyInnerApiKeySecret }}
      key: plugin-dify-inner-api-key
{{- else if .Values.pluginDaemon.difyInnerApiKey }}
  value: {{ .Values.pluginDaemon.difyInnerApiKey | quote }}
{{- else }}
{{- end }}

- name: INNER_API_KEY_FOR_PLUGIN
{{- if .Values.pluginDaemon.difyInnerApiKeySecret }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pluginDaemon.difyInnerApiKeySecret }}
      key: plugin-dify-inner-api-key
{{- else if .Values.pluginDaemon.difyInnerApiKey }}
  value: {{ .Values.pluginDaemon.difyInnerApiKey | quote }}
{{- else }}
{{- end }}

- name: PLUGIN_DIFY_INNER_API_URL
  value: http://{{ include "dify.fullname" . }}-api-svc.{{ .Values.global.namespace }}.svc.cluster.local:{{ .Values.api.service.port }}

{{- end }} # end of dify.commonBackendEnvs

{{- end }}
