{{/*
Criar nossas tags
*/}}

{{- define "app.labels" -}}
app: {{ .labels.app | quote }}
live: {{ .labels.live | quote }}
env: {{ .labels.env | quote }}
{{- end -}}
