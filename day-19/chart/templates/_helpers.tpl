{{/*
Criar nossas tags
*/}}

{{- define "app.labels" -}}
app: {{ .labels.app | quote }}
live: {{ .labels.live | quote }}
env: {{ .labels.env | quote }}
{{- end -}}


{{/*
Definir limites de recursos
*/}}

{{- define "app.resources" -}}
{{- if .resources }}
resources:
  requests:
    memory: {{ .resources.requests.memory }}
    cpu: {{ .resources.requests.cpu }}
  limits:
    memory: {{ .resources.limits.memory }}
    cpu: {{ .resources.limits.cpu }}
{{- end }}
{{- end -}}


{{/*
Definir portas dos containers
*/}}

{{- define "app.ports" -}}
{{ range .ports }}
  - containerPort: {{ .port }}
{{- end }}
{{- end -}}

{{/*
Definir os configmaps
*/}}
{{- define "database.configmaps" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .component }}-database-config
data:
  app-config.yaml: |
    {{- toYaml .config | nindent 4 }}
{{- end -}}


{{/*
Definir os configmaps
*/}}
{{- define "observability.configmaps" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .component }}-observability-config
data:
  app-config.yaml: |
    {{- toYaml .config | nindent 4 }}
{{- end -}}