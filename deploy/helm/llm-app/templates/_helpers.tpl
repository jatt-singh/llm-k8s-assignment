{{/* Common labels. */}}
{{- define "llm-app.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/part-of: llmstack
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/version: {{ .root.Values.image.tag | quote }}
helm.sh/chart: {{ .root.Chart.Name }}-{{ .root.Chart.Version }}
environment: {{ .root.Values.environment }}
{{- end }}

{{- define "llm-app.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/part-of: llmstack
{{- end }}

{{/* Image reference for one of our images. A per-service imageTag overrides
     the release-wide tag (used by the bad-release demo to break one service). */}}
{{- define "llm-app.image" -}}
{{- $svc := index (.root.Values.services | default dict) .name | default dict -}}
{{- $tag := $svc.imageTag | default .root.Values.image.tag -}}
{{- $_ := required "image.tag is required (set by scripts/ci.sh)" $tag -}}
{{ .root.Values.image.registry }}/{{ .name }}:{{ $tag }}
{{- end }}

{{/* Pod-level security context satisfying the "restricted" Pod Security Standard. */}}
{{- define "llm-app.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
fsGroup: 65532
fsGroupChangePolicy: OnRootMismatch
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/* Container-level security context. */}}
{{- define "llm-app.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop: ["ALL"]
{{- end }}

{{- define "llm-app.modelDir" -}}/models/{{ .Values.model.revision }}{{- end }}
{{- define "llm-app.modelPath" -}}{{ include "llm-app.modelDir" . }}/{{ .Values.model.file }}{{- end }}
{{- define "llm-app.modelMarker" -}}{{ include "llm-app.modelPath" . }}.verified{{- end }}
