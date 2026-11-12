{{/* Ім'я чарта */}}
{{- define "tickets.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Повне ім'я об'єктів: <реліз>-<чарт>, або лише <реліз>, якщо воно вже містить ім'я чарта */}}
{{- define "tickets.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Імена компонентів */}}
{{- define "tickets.app.fullname" -}}
{{- printf "%s-app" (include "tickets.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "tickets.db.fullname" -}}
{{- printf "%s-db" (include "tickets.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "tickets.keycloak.fullname" -}}
{{- printf "%s-keycloak" (include "tickets.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* chart: ім'я-версія */}}
{{- define "tickets.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Мітки-селектори. Виклик: include "tickets.selectorLabels" (dict "ctx" $ "component" "app") */}}
{{- define "tickets.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tickets.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Повний набір міток. Виклик: include "tickets.labels" (dict "ctx" $ "component" "app") */}}
{{- define "tickets.labels" -}}
helm.sh/chart: {{ include "tickets.chart" .ctx }}
{{ include "tickets.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: tickets
{{- end -}}

{{/* Тег образу застосунку */}}
{{- define "tickets.app.image" -}}
{{- printf "%s:%s" .Values.app.image.repository (default .Chart.AppVersion .Values.app.image.tag) -}}
{{- end -}}

{{/* Ім'я Secret і ConfigMap */}}
{{- define "tickets.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "tickets.fullname" .) -}}
{{- end -}}
{{- end -}}
{{- define "tickets.app.configName" -}}
{{- printf "%s-config" (include "tickets.app.fullname" .) -}}
{{- end -}}

{{/* Адреса Keycloak для браузера */}}
{{- define "tickets.keycloak.publicUrl" -}}
{{- if .Values.ingress.enabled -}}
{{- printf "http://%s" .Values.ingress.keycloakHost -}}
{{- else -}}
{{- .Values.keycloak.publicUrl -}}
{{- end -}}
{{- end -}}


{{/* Шаблон пода застосунку — спільний для Deployment і Rollout */}}
{{- define "tickets.app.podTemplate" -}}
metadata:
  labels:
    {{- include "tickets.labels" (dict "ctx" $ "component" "app") | nindent 4 }}
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/app-configmap.yaml") . | sha256sum }}
    {{- if not .Values.secrets.existingSecret }}
    checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    {{- end }}
spec:
  {{- with .Values.app.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  initContainers:
    - name: wait-for-db
      image: "{{ .Values.db.image.repository }}:{{ .Values.db.image.tag }}"
      command: ["sh", "-c", "until pg_isready -h {{ include "tickets.db.fullname" . }} -p {{ .Values.db.port }}; do echo waiting for db; sleep 2; done"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { cpu: 100m, memory: 64Mi }
  containers:
    - name: app
      image: {{ include "tickets.app.image" . | quote }}
      imagePullPolicy: {{ .Values.app.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ .Values.app.containerPort }}
      envFrom:
        - configMapRef:
            name: {{ include "tickets.app.configName" . }}
      env:
        - name: SPRING_DATASOURCE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ include "tickets.secretName" . }}
              key: db-password
        - name: KEYCLOAK_CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: {{ include "tickets.secretName" . }}
              key: keycloak-client-secret
              optional: true
        - name: JAVA_TOOL_OPTIONS
          value: {{ .Values.app.config.javaToolOptions | quote }}
      resources:
        {{- toYaml .Values.app.resources | nindent 8 }}
      startupProbe:
        httpGet:
          path: {{ .Values.app.probes.path }}
          port: http
        periodSeconds: 5
        failureThreshold: 36
      readinessProbe:
        httpGet:
          path: {{ .Values.app.probes.path }}
          port: http
        periodSeconds: 5
        failureThreshold: 3
      livenessProbe:
        httpGet:
          path: {{ .Values.app.probes.path }}
          port: http
        periodSeconds: 10
        failureThreshold: 3
{{- end -}}
