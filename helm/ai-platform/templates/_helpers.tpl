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

{{/*
Phase 12: ai-gateway's own name/selector/labels, deliberately NOT built on top of
ai-platform.name/selectorLabels/labels above. ai-service's Deployment selector is
app.kubernetes.io/name: ai-service (values.yaml's nameOverride, not the chart name) and is
immutable on an already-applied release (every polaris-dev/staging/prod namespace since
Phase 4/5) -- changing it, or giving the gateway's pods a label set that is a superset of it
(which Kubernetes treats as ALSO matching that selector), would make `helm upgrade` fail
outright or make two Deployments fight over the same pods. The two name values ("ai-service"
vs "ai-gateway" below) already can't collide, but giving ai-gateway its own dedicated helper
rather than a second nameOverride-style value keeps that guarantee explicit and reviewable
here, instead of implicit in a values.yaml string nobody is required to keep distinct -- see
ADR-30.
*/}}
{{- define "ai-platform.gatewayName" -}}
ai-gateway
{{- end -}}

{{- define "ai-platform.gatewaySelectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-platform.gatewayName" . }}
{{- end -}}

{{- define "ai-platform.gatewayLabels" -}}
{{ include "ai-platform.gatewaySelectorLabels" . }}
app.kubernetes.io/part-of: polaris
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
environment: {{ required "values-<env>.yaml must set 'environment'" .Values.environment }}
{{- end -}}
