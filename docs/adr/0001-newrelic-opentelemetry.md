# ADR 0001: New Relic through private OpenTelemetry collectors

Status: Accepted for implementation; deployment and ingestion acceptance remain separate gates.

## Context

GarageFlow needs API traces, correlated logs, HTTP/runtime metrics and Kubernetes health data. Its small EKS worker pool cannot justify a local telemetry storage stack. The API domain and application layers must remain independent of observability vendors. Lambda instrumentation is outside this decision.

## Decision

Use the official New Relic Kubernetes OpenTelemetry Helm chart 0.14.2 with NRDOT 1.19.0. A SHA-256 pins the release archive, including its dependency charts. Explicit image versions replace floating defaults. Keep Kubernetes metric receivers and the vendor's low-data transformations, and add HTTP/protobuf application pipelines to the deployment collector. The API uses the private `garageflow-otel.newrelic.svc.cluster.local:4318` ClusterIP service; collectors export to the US HTTPS OTLP endpoint. No public ingress is added.

Disable file log pipelines and Kubernetes events. Application logs have one ingestion path through OTLP. The API owns telemetry privacy and safe route-based dimensions; collector enrichment adds Kubernetes and environment identity without extracting arbitrary pod annotations or labels. API code receives no New Relic credential.

Restrict the daemonset's `resource_detection/cloudproviders` detector list to `[env]`. The upstream cloud detectors can invoke EC2 discovery and fail collector startup when Academy supplies no pod AWS credentials. The existing environment/system detector, Kubernetes receivers, Kubernetes attribute processor and explicit chart cluster name remain enabled. This intentionally gives up automatic cloud provider, account, region, instance and cloud resource-ID enrichment; Kubernetes collection must not require broader IAM, IMDS access, outbound routes or copied AWS credentials.

Keep the ingestion key in a Kubernetes Secret, created separately through stdin and referenced by Helm. Do not put it in Terraform, release values, command arguments or process output. Management operations such as dashboard publication need separate credentials and are not inferred from an ingestion key. The checked-in dashboard template can be rendered for a specific account/environment and imported manually.

Run installation only from protected main/develop workflows behind explicit environment opt-in. Validate the platform metadata against live AWS account, cluster and VPC identity. Temporarily lease runner `/32` access and retain an update identifier until AWS reports a terminal state. Restore only an unchanged owned configuration; concurrent changes and uncertain submissions require reconciliation rather than a blind overwrite.

## Consequences

The deployment adds one collector per node, one cluster collector and kube-state-metrics. Two nodes require 480 MiB/325m steady requests, with 704 MiB/1600m steady limits and additional rollout headroom. Capacity must be measured before enablement; this decision does not authorize resizing or HPA changes. Memory limits, batching, bounded queues and finite retries favor business availability over telemetry durability. There is no persistent telemetry queue.

Read-only cluster discovery RBAC includes node statistics/proxy access but cannot read Kubernetes Secrets or ConfigMaps or mutate workloads. kube-state-metrics uses an explicit collector allowlist: daemonsets, deployments, horizontal pod autoscalers, jobs, namespaces, nodes, pods, replicasets and statefulsets. Its broader default discovery list is not enabled. The init utility uses the existing Kubernetes API and shares the daemonset resource budget. ClusterIP HTTP is unencrypted inside the cluster and is not a tenant isolation boundary. HTTPS protects export to New Relic.

Successful chart rendering, configuration validation and installation do not demonstrate data acceptance. Validate a real request, log/trace correlation, metrics and resource overhead after merge. Missing samples may mean backend failure or an Academy shutdown; they do not establish availability. Business duration dashboards require independent domain history work.

## Sources

- [New Relic Kubernetes OpenTelemetry installation](https://docs.newrelic.com/docs/kubernetes-pixie/k8s-otel/install/)
- [Pinned official chart release](https://github.com/newrelic/helm-charts/releases/tag/nr-k8s-otel-collector-0.14.2)
- [OpenTelemetry Collector configuration](https://opentelemetry.io/docs/collector/configuration/)
