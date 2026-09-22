{{/*
helm/ai-platform/templates/_helpers.tpl — Phase 5.

Two label sets on purpose:
  - ai-platform.selectorLabels: ONLY app.kubernetes.io/name. Used for every selector
    (Deployment spec.selector, Service, PodDisruptionBudget, NetworkPolicy podSelector) because
    Deployment selectors are immutable after creation — adding a label here later would break
    upgrades. It is also exactly the selector Phase 4's raw manifests already used, so a chart
    install into an already-Phase-4-deployed namespace targets the same pods.
  - ai-platform.labels: the selector labels plus Helm's own bookkeeping (chart, managed-by,
    environment). Used on metadata.labels only, never on a selector.
*/}}

{{- define "ai-platform.name" -}}
{{- .Values.nameOverride | default .Chart.Name -}}
{{- end -}}

{{- define "ai-platform.namespace" -}}
{{- required "values-<env>.yaml must set 'namespace' (see values-dev.yaml / values-staging.yaml / values-prod.yaml)" .Values.namespace -}}
{{- end -}}

{{- define "ai-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-platform.name" . }}
{{- end -}}

{{- define "ai-platform.labels" -}}
{{ include "ai-platform.selectorLabels" . }}
app.kubernetes.io/part-of: polaris
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
environment: {{ required "values-<env>.yaml must set 'environment'" .Values.environment }}
{{- end -}}
