{{/*
Labels padrão para todos os recursos do chart.
*/}}
{{- define "tipsbank.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
team: {{ .Values.global.team }}
env: {{ .Values.global.env }}
{{- end -}}

{{/*
DB_URL para api-contas (postgres no mesmo namespace — usa short name).
*/}}
{{- define "tipsbank.contas.dburl" -}}
{{- printf "postgresql+psycopg://%s:%s@postgres:5432/%s" .Values.contas.postgres.user .Values.contas.postgres.password .Values.contas.postgres.db -}}
{{- end -}}

{{/*
DB_URL para api-transacoes (postgres em namespace diferente — usa FQDN).
*/}}
{{- define "tipsbank.transacoes.dburl" -}}
{{- printf "postgresql+psycopg://%s:%s@postgres.tipsbank-contas.svc.cluster.local:5432/%s" .Values.contas.postgres.user .Values.contas.postgres.password .Values.contas.postgres.db -}}
{{- end -}}
