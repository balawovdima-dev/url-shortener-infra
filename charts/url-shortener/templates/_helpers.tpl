{{/*
Common labels for resource metadata. Deliberately NOT used in Deployment
selectors or pod templates: selectors are immutable and stay `app: <name>`.
*/}}
{{- define "url-shortener.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "url-shortener.image" -}}
image: {{ printf "%s:%s" .repository .tag | quote }}
{{- with .pullPolicy }}
imagePullPolicy: {{ . }}
{{- end }}
{{- end }}

{{- define "url-shortener.ingressPath" -}}
- path: {{ .path }}
  pathType: {{ .type }}
  backend:
    service:
      name: {{ .svc }}
      port:
        number: 80
{{- end }}

{{- define "url-shortener.ingressTLS" -}}
tls:
  - secretName: {{ .Values.ingress.tlsSecret | quote }}
    {{- with .Values.ingress.host }}
    hosts:
      - {{ . | quote }}
    {{- end }}
{{- end }}
