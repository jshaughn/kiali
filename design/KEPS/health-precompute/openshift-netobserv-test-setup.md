# OpenShift Test Environment: Kiali Health Metrics + NetObserv Integration

This document describes how to set up an OpenShift environment for testing the
integration of Kiali's `kiali_health_status` Prometheus metric with NetObserv's
Network Health dashboard. It captures the full setup process, including the
workarounds required for OpenShift's dual-Prometheus monitoring architecture.

## Automated Setup

All of the manual steps described in this document are automated by the
`hack/install-netobserv.sh` script. To set up the complete environment in a
single command:

```bash
hack/install-netobserv.sh install-all
```

Or install individual components:

```bash
hack/install-netobserv.sh install-netobserv
hack/install-netobserv.sh install-istio
hack/install-netobserv.sh install-bookinfo
hack/install-netobserv.sh install-kiali
```

Run `hack/install-netobserv.sh -h` for all available options and commands.

The rest of this document explains each step in detail for reference and
troubleshooting.

## Table of Contents

- [Automated Setup](#automated-setup)
- [Goal](#goal)
- [OpenShift Monitoring Architecture](#openshift-monitoring-architecture)
- [Environment Setup](#environment-setup)
  - [1. Enable User Workload Monitoring](#1-enable-user-workload-monitoring)
  - [2. Install Network Observability Operator](#2-install-network-observability-operator)
  - [3. Install Istio via Sail Operator](#3-install-istio-via-sail-operator)
  - [4. Deploy Bookinfo Demo Application](#4-deploy-bookinfo-demo-application)
  - [5. Configure Istio Metrics Collection](#5-configure-istio-metrics-collection)
  - [6. Install Kiali (Dev Builds)](#6-install-kiali-dev-builds)
  - [7. Configure Kiali for OpenShift Prometheus](#7-configure-kiali-for-openshift-prometheus)
  - [8. Configure Kiali Metrics Scraping](#8-configure-kiali-metrics-scraping)
  - [9. Create NetObserv Health Alerting Rule](#9-create-netobserv-health-alerting-rule)
- [Verification](#verification)
- [Troubleshooting Notes](#troubleshooting-notes)

## Goal

Validate that Kiali's `kiali_health_status` metric can be used to create
Prometheus alerting rules that surface on NetObserv's Network Health page. The
`kiali_health_status` metric uses a state-cardinality pattern: for each
app/service/workload, exactly one status label is set to `1` while others are
`0`.

Example metric:

```
kiali_health_status{
  cluster="Kubernetes",
  namespace="bookinfo",
  health_type="app",
  name="reviews",
  status="Healthy"
} 1
```

See [proposal.md](proposal.md) for the full design of the `kiali_health_status`
metric.

## OpenShift Monitoring Architecture

OpenShift splits its monitoring stack into two separate Prometheus instances.
Understanding this split is essential because it determines where
ServiceMonitors and PodMonitors must be placed, and which namespaces they can
target.

### Platform Prometheus (`openshift-monitoring/prometheus-k8s`)

- Managed entirely by the Cluster Monitoring Operator (CMO).
- Monitors OpenShift platform components: API server, etcd, kubelet,
  node-exporter, OpenShift operators, etc.
- Only scrapes namespaces labeled `openshift.io/cluster-monitoring=true`.
- Users **cannot** add custom ServiceMonitors/PodMonitors to it -- CMO controls
  what gets scraped.
- RBAC is tightly scoped to specific platform namespaces that CMO manages.

### User Workload Prometheus (`openshift-user-workload-monitoring/prometheus-user-workload`)

- Enabled by setting `enableUserWorkload: true` in the
  `cluster-monitoring-config` ConfigMap in `openshift-monitoring`.
- Monitors user-deployed applications.
- Scrapes namespaces that do **not** have `openshift.io/cluster-monitoring=true`.
- Users **can** add their own ServiceMonitors, PodMonitors, and PrometheusRules.
- ServiceMonitors/PodMonitors can only target services/pods in their own
  namespace (OpenShift ignores `namespaceSelector` in these resources).

### Thanos Querier (`openshift-monitoring/thanos-querier`)

- Sits in front of both Prometheus instances and federates their data.
- Provides a unified query endpoint at
  `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091`.
- Requires bearer token authentication and TLS.
- Kiali is configured to query this endpoint for a unified view of all metrics.

### The `istio-system` Namespace Gap

By default, `istio-system` may carry the `openshift.io/cluster-monitoring=true`
label (added by the Sail operator or cluster setup). This creates a problem:

1. The **platform Prometheus** accepts ServiceMonitors from this namespace but
   lacks RBAC to discover endpoints there (CMO only grants access to namespaces
   it explicitly manages).
2. The **user-workload Prometheus** explicitly skips this namespace because of
   the label.
3. Result: ServiceMonitors in `istio-system` are accepted by one Prometheus but
   served by neither.

**Fix:** Remove the label so the user-workload Prometheus handles `istio-system`:

```bash
oc label namespace istio-system openshift.io/cluster-monitoring-
```

## Environment Setup

Prerequisites: OpenShift CRC installed and running, logged in as admin.

### 1. Enable User Workload Monitoring

This allows Prometheus to scrape metrics from user-defined namespaces.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

Wait for the user-workload-monitoring pods to come up:

```bash
oc get pods -n openshift-user-workload-monitoring
```

### 2. Install Network Observability Operator

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-netobserv-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: netobserv-operator-group
  namespace: openshift-netobserv-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: netobserv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the operator to install, then create the FlowCollector in metrics-only
mode (no Loki required):

```bash
oc apply -f - <<'EOF'
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
  namespace: netobserv
spec:
  namespace: netobserv
  deploymentModel: Direct
  agent:
    type: eBPF
    ebpf:
      sampling: 50
      features:
        - DNSTracking
        - FlowRTT
        - PacketDrop
  processor:
    metrics:
      server:
        port: 9102
      disableAlerts: []
  loki:
    mode: Manual
    manual:
      authToken: Disabled
  consolePlugin:
    register: true
    portNaming:
      enable: true
EOF
```

### 3. Install Istio via Sail Operator

Install the Sail operator from OperatorHub:

```bash
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sailoperator
  namespace: openshift-operators
spec:
  channel: candidates
  installPlanApproval: Automatic
  name: sailoperator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the operator, then deploy Istio:

```bash
oc create namespace istio-system 2>/dev/null
oc create namespace istio-cni 2>/dev/null

oc apply -f - <<'EOF'
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  namespace: istio-system
  values:
    pilot:
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
---
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
  namespace: istio-system
spec:
  namespace: istio-cni
EOF
```

**Important:** Remove the cluster-monitoring label from `istio-system` so
the user-workload Prometheus can handle ServiceMonitors there (see
[The istio-system Namespace Gap](#the-istio-system-namespace-gap)):

```bash
oc label namespace istio-system openshift.io/cluster-monitoring-
```

### 4. Deploy Bookinfo Demo Application

From the Kiali repository root:

```bash
hack/istio/install-bookinfo-demo.sh -c oc -tg --mongo
```

This installs the Bookinfo application with a traffic generator in the
`bookinfo` namespace.

### 5. Configure Istio Metrics Collection

Create a ServiceMonitor for istiod and a PodMonitor for the Istio sidecar
proxies. The PodMonitor uses relabeling rules that work with native Kubernetes
sidecar containers (init containers with `restartPolicy: Always`), which is how
OSSM 3.x / Sail injects the `istio-proxy`.

See: https://kiali.io/docs/configuration/multi-cluster/acm-observability/#prerequisites

**ServiceMonitor for istiod** (in `istio-system`):

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istiod-monitor
  namespace: istio-system
spec:
  targetLabels:
  - app
  selector:
    matchLabels:
      istio: pilot
  endpoints:
  - port: http-monitoring
    interval: 30s
EOF
```

**PodMonitor for Istio proxies** (must be applied in each mesh namespace):

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istio-proxies-monitor
  namespace: bookinfo
spec:
  selector:
    matchExpressions:
    - key: istio-prometheus-ignore
      operator: DoesNotExist
  podMetricsEndpoints:
  - path: /stats/prometheus
    interval: 30s
    relabelings:
    - action: keep
      sourceLabels: ["__meta_kubernetes_pod_container_name"]
      regex: "istio-proxy"
    - action: keep
      sourceLabels: ["__meta_kubernetes_pod_annotationpresent_prometheus_io_scrape"]
    - action: replace
      regex: (\d+);(([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4})
      replacement: '[$2]:$1'
      sourceLabels: ["__meta_kubernetes_pod_annotation_prometheus_io_port","__meta_kubernetes_pod_ip"]
      targetLabel: "__address__"
    - action: replace
      regex: (\d+);((([0-9]+?)(\.|$)){4})
      replacement: '$2:$1'
      sourceLabels: ["__meta_kubernetes_pod_annotation_prometheus_io_port","__meta_kubernetes_pod_ip"]
      targetLabel: "__address__"
    - sourceLabels: ["__meta_kubernetes_pod_label_app_kubernetes_io_name","__meta_kubernetes_pod_label_app"]
      separator: ";"
      targetLabel: "app"
      action: replace
      regex: "(.+);.*|.*;(.+)"
      replacement: "${1}${2}"
    - sourceLabels: ["__meta_kubernetes_pod_label_app_kubernetes_io_version","__meta_kubernetes_pod_label_version"]
      separator: ";"
      targetLabel: "version"
      action: replace
      regex: "(.+);.*|.*;(.+)"
      replacement: "${1}${2}"
    - sourceLabels: ["__meta_kubernetes_namespace"]
      action: replace
      targetLabel: namespace
EOF
```

Key points about the PodMonitor relabeling:

- `keep` on `__meta_kubernetes_pod_container_name = istio-proxy`: Works with
  native K8s sidecars because Prometheus 3.x discovers init containers and
  populates `__meta_kubernetes_pod_container_name` for them.
- `keep` on `prometheus_io_scrape` annotation: Only scrapes pods that Istio has
  annotated with `prometheus.io/scrape: "true"`.
- Address rewriting: Uses the `prometheus.io/port` annotation (15020) and pod IP
  to construct the scrape target address, supporting both IPv4 and IPv6.
- Label extraction: Pulls `app` and `version` labels from pod labels, falling
  back between `app.kubernetes.io/name` and `app`.

### 6. Install Kiali (Dev Builds)

Build and deploy Kiali using dev images:

```bash
HELM_CHARTS_REPO_PULL=false \
HELM=/usr/bin/helm \
AUTH_STRATEGY=anonymous \
CLUSTER_TYPE=openshift \
make clean build-ui build cluster-push operator-create kiali-create
```

### 7. Configure Kiali for OpenShift Prometheus

Kiali defaults to `http://prometheus.istio-system:9090` which doesn't exist on
OpenShift. Configure it to use the Thanos Querier.

**Grant the Kiali service account access to monitoring data:**

```bash
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  system:serviceaccount:istio-system:kiali-service-account
```

**Patch the Kiali CR:**

```bash
oc patch kiali kiali -n kiali-operator --type merge -p '
{
  "spec": {
    "external_services": {
      "prometheus": {
        "url": "https://thanos-querier.openshift-monitoring.svc.cluster.local:9091",
        "auth": {
          "type": "bearer",
          "use_kiali_token": true,
          "insecure_skip_verify": true
        }
      }
    }
  }
}'
```

Notes:

- `use_kiali_token: true` tells Kiali to authenticate with the Thanos Querier
  using its own service account token.
- `insecure_skip_verify: true` is needed because with `auth_strategy: anonymous`,
  Kiali only loads the `additional-ca-bundle.pem` CA, not the OpenShift service
  CA (`service-ca.crt`). See `config/config.go:getCABundlePaths()` -- the
  OpenShift serving CA is only loaded for `openshift` and `openid` auth
  strategies. This is arguably a gap worth fixing.

### 8. Configure Kiali Metrics Scraping

Create a ServiceMonitor so that Prometheus scrapes Kiali's own metrics
(including `kiali_health_status`) from its metrics port (9090).

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kiali-monitor
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kiali
  endpoints:
  - port: tcp-metrics
    path: /metrics
    interval: 30s
    scheme: https
    tlsConfig:
      insecureSkipVerify: true
    honorLabels: true
EOF
```

The Kiali operator does not create a ServiceMonitor. The Kiali service exposes
the metrics port as `tcp-metrics` on port 9090 using HTTPS (OpenShift
serving-cert).

**Important:** `honorLabels: true` is required. Without it, OpenShift's
user-workload Prometheus overwrites the `namespace` label with the scrape
target's namespace (`istio-system`) via `enforcedNamespaceLabel`. The original
namespace value is moved to `exported_namespace`. While `honorLabels: true`
does not prevent this relabeling (it's enforced at the operator level), it
preserves other metric labels. The `exported_namespace` label is used in
alerting rules to reference the actual workload namespace.

### 9. Create NetObserv Health Alerting Rule

Create a `PrometheusRule` that surfaces Kiali health data on NetObserv's
Network Health page. The rule fires when a workload has been unhealthy for more
than 25% of the past 10 minutes.

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kiali-health-alerts
  namespace: istio-system
  labels:
    netobserv: "true"
spec:
  groups:
  - name: KialiHealthAlerts
    rules:
    - alert: KialiWorkloadUnhealthy
      annotations:
        netobserv_io_network_health: '{"workloadLabels":["name"],"namespaceLabels":["exported_namespace"],"kindLabels":["kind"],"threshold":"25","unit":"%","upperBound":"100","links":[{"name":"Inspect Kiali console","url":"https://kiali-istio-system.apps-crc.testing/console/overview"}]}'
        description: >-
          Kiali reports workload {{ $labels.name }} in namespace
          {{ $labels.exported_namespace }} has been unhealthy for more than
          25% of the past 10 minutes.
        summary: "Workload unhealthy (Kiali health)"
      expr: |-
        (1 - avg_over_time(kiali_health_status{status="Healthy", health_type="workload"}[10m])) * 100 > 25
      for: 5m
      labels:
        app: netobserv
        kind: Workload
        netobserv: "true"
        severity: info
EOF
```

#### How the `netobserv_io_network_health` annotation works

The `netobserv_io_network_health` annotation is a JSON string that controls how
the alert appears on NetObserv's Network Health page. The NetObserv console
plugin (see
[health-helper.ts](https://github.com/netobserv/network-observability-console-plugin/blob/main/web/src/components/health/health-helper.ts))
parses this annotation to determine tab placement, thresholds, and links.

**Tab categorization** is determined by which label arrays are present in the
annotation:

| Labels present | Tab |
|---|---|
| `workloadLabels` + `namespaceLabels` + `kindLabels` (all three) | **Workloads** (internally: `Owner`) |
| `namespaceLabels` only | **Namespaces** |
| `nodeLabels` only | **Nodes** |
| None of the above | **Global** |

For each label array, the plugin looks up the first matching key in the alert's
Prometheus labels and uses its value. All three must resolve to non-empty values
for the Workloads tab.

**Annotation fields:**

| Field | Description |
|---|---|
| `workloadLabels` | Label key(s) for the workload name (e.g., `["name"]`) |
| `namespaceLabels` | Label key(s) for the namespace (e.g., `["exported_namespace"]`) |
| `kindLabels` | Label key(s) for the resource kind (e.g., `["kind"]`) |
| `threshold` | The alerting threshold value (for display) |
| `unit` | Unit string (e.g., `"%"`) |
| `upperBound` | Maximum value of the metric range (e.g., `"100"`) |
| `links` | Array of `{name, url}` objects shown in the kebab menu |

**Alert labels:**

| Label | Purpose |
|---|---|
| `netobserv: "true"` | Required for NetObserv to discover the alert |
| `kind: Workload` | Static label resolved by `kindLabels: ["kind"]` |
| `severity: info` | Severity level (info/warning/critical) |
| `app: netobserv` | Convention for NetObserv-related alerts |

**Why `exported_namespace` instead of `namespace`:**
OpenShift's user-workload Prometheus enforces `namespace` relabeling based on
the scrape target's namespace. Since Kiali runs in `istio-system`, all
`kiali_health_status` metrics get `namespace=istio-system` regardless of the
workload's actual namespace. The original `namespace` value from the metric is
moved to `exported_namespace`. Using `"namespaceLabels": ["exported_namespace"]`
correctly references the actual workload namespace (e.g., `bookinfo`).

**Why `description` instead of just `message`:**
The NetObserv console plugin reads `a.annotations.description` for the tooltip
text displayed in the side panel. Both `description` and `message` should be set
for compatibility with different alert viewers.

#### Note on templated link URLs

Prometheus resolves `{{ $labels.xxx }}` templates in per-alert annotations, so
dynamic URLs like
`https://kiali.example.com/console/namespaces/{{ $labels.exported_namespace }}/workloads/{{ $labels.name }}`
**do** get correctly resolved at the Prometheus API level. However, the NetObserv
console plugin currently reads the `netobserv_io_network_health` annotation from
the **rule-level** annotations (where templates are raw/unresolved) rather than
from individual **alert-level** annotations (where they are resolved). This means
templated link URLs appear as literal `{{ $labels.xxx }}` text in the UI. This
has been reported to the NetObserv team. Until it is fixed, use static URLs in
the `links` array.

## Verification

### Istio Metrics

Check that `istio_requests_total` is available:

```bash
# Via OpenShift Console: Observe -> Metrics
# Query: istio_requests_total{namespace="bookinfo"}

# Or via CLI:
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus -- curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count(istio_requests_total{namespace="bookinfo"})'
```

### Kiali Health Metrics

Check that `kiali_health_status` is available:

```bash
# Via OpenShift Console: Observe -> Metrics
# Query: kiali_health_status{namespace="bookinfo"}

# Or via CLI:
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus -- curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=kiali_health_status{namespace="bookinfo",status="Healthy"}'
```

### Scrape Targets

Verify all targets are healthy:

```bash
# Istio proxy targets (8 bookinfo pods expected):
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus -- curl -s \
  'http://localhost:9090/api/v1/targets?scrapePool=podMonitor/bookinfo/istio-proxies-monitor/0' \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(f'{t[\"labels\"][\"pod\"]}: {t[\"health\"]}')
"

# Kiali target (1 expected):
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus -- curl -s \
  'http://localhost:9090/api/v1/targets?scrapePool=serviceMonitor/istio-system/kiali-monitor/0' \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(f'{t[\"scrapeUrl\"]}: {t[\"health\"]}')
"
```

## Troubleshooting Notes

### ServiceMonitor not discovered

- Check which Prometheus owns the namespace:
  `oc get ns <namespace> --show-labels | grep cluster-monitoring`
- If the namespace has `openshift.io/cluster-monitoring=true`, ServiceMonitors
  go to the platform Prometheus (which may lack RBAC). Remove the label to use
  user-workload Prometheus instead.

### TLS errors connecting to Thanos Querier

- With `auth_strategy: anonymous`, Kiali does not load the OpenShift service CA.
  Set `insecure_skip_verify: true` in the Prometheus auth config, or switch to
  `auth_strategy: openshift`.

### No `istio_requests_total` data

- Verify the PodMonitor targets are up in Prometheus.
- Ensure traffic is flowing (check the traffic generator pod in `bookinfo`).
- The PodMonitor must be in the same namespace as the pods being scraped.

### Platform Prometheus RBAC errors

- Check logs: `oc logs -n openshift-monitoring prometheus-k8s-0 -c prometheus | grep "forbidden"`
- The platform Prometheus SA only has RBAC for namespaces CMO explicitly manages.
  Adding a ServiceMonitor in other namespaces with `cluster-monitoring=true`
  will silently fail target discovery.
