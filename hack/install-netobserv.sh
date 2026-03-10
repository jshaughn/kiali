#!/bin/bash

##############################################################################
# install-netobserv.sh
#
# This script sets up an OpenShift environment for testing Kiali's
# kiali_health_status metric integration with NetObserv's Network Health
# dashboard. It installs and configures:
#
#   - User Workload Monitoring (Prometheus for user namespaces)
#   - Network Observability operator (metrics-only mode, no Loki)
#   - Istio via the Sail operator
#   - Bookinfo demo application with traffic generation
#   - Kiali (dev builds) configured to query the Thanos Querier
#   - Prometheus ServiceMonitors/PodMonitors for all metric collection
#
# OpenShift Monitoring Architecture:
#   OpenShift runs two Prometheus instances:
#
#   Platform Prometheus (openshift-monitoring/prometheus-k8s):
#     Managed by the Cluster Monitoring Operator (CMO). Monitors OpenShift
#     platform components. Users cannot add custom ServiceMonitors here.
#     Only scrapes namespaces with openshift.io/cluster-monitoring=true.
#
#   User Workload Prometheus (openshift-user-workload-monitoring/prometheus-user-workload):
#     Enabled via enableUserWorkload: true in cluster-monitoring-config.
#     Monitors user applications. Users CAN add ServiceMonitors and PodMonitors.
#     Scrapes namespaces that do NOT have openshift.io/cluster-monitoring=true.
#     ServiceMonitors can only target services in their own namespace.
#
#   Thanos Querier (openshift-monitoring/thanos-querier):
#     Federates both Prometheus instances. Kiali queries this for a unified
#     view at https://thanos-querier.openshift-monitoring.svc.cluster.local:9091.
#     Requires bearer token auth and TLS.
#
# The istio-system Namespace:
#   By default, istio-system may have openshift.io/cluster-monitoring=true,
#   which causes the platform Prometheus to claim it. But the platform
#   Prometheus lacks RBAC to discover endpoints there (CMO only manages its
#   own namespaces). The user-workload Prometheus skips it because of the
#   label. This script removes the label so user-workload Prometheus handles
#   ServiceMonitors in istio-system correctly.
#
# Kiali Metrics (kiali_health_status):
#   Kiali exposes health status as a Prometheus gauge metric using a
#   state-cardinality pattern. This script creates a ServiceMonitor to
#   scrape it, making it available for NetObserv Network Health alerting.
#
# The script supports:
#   install-all          - Install everything (UWM + NetObserv + Istio + Bookinfo + Kiali)
#   install-components   - Install all components, skipping already-installed ones
#   install-netobserv    - Install NetObserv operator + FlowCollector (metrics-only)
#   uninstall-netobserv  - Remove NetObserv
#   status-netobserv     - Check NetObserv status
#   install-istio        - Install Istio via Sail + configure metrics collection
#   uninstall-istio      - Remove Istio
#   status-istio         - Check Istio status
#   install-bookinfo     - Deploy Bookinfo with traffic generator + PodMonitor
#   uninstall-bookinfo   - Remove Bookinfo
#   install-kiali        - Build & deploy Kiali, configure Prometheus, create ServiceMonitor
#   uninstall-kiali      - Remove Kiali
#   status-kiali         - Check Kiali status
#   status               - Show status of all components
#
# Prerequisites:
#   - OpenShift cluster accessible via 'oc' CLI (e.g. CRC)
#   - Cluster-admin privileges
#   - For install-kiali: make, helm, and access to Kiali git repositories
#
# Examples:
#   $0 install-all                    # Install everything from scratch
#   $0 install-components             # Install missing components on existing cluster
#   $0 install-netobserv              # Install just NetObserv
#   $0 install-istio                  # Install just Istio
#   $0 install-bookinfo               # Install just Bookinfo
#   $0 install-kiali                  # Build and install Kiali
#   $0 --skip-build install-kiali     # Install Kiali without rebuilding
#   $0 status                         # Check status of everything
#   $0 uninstall-kiali                # Remove Kiali
#   $0 uninstall-bookinfo             # Remove Bookinfo
#   $0 uninstall-istio                # Remove Istio
#   $0 uninstall-netobserv            # Remove NetObserv
#
##############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Default values
DEFAULT_CLIENT_EXE="oc"
DEFAULT_TIMEOUT="600"
DEFAULT_KIALI_NAMESPACE="istio-system"
DEFAULT_BOOKINFO_NAMESPACE="bookinfo"
DEFAULT_KIALI_REPO_DIR="$(cd "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
DEFAULT_SKIP_BUILD="false"

# Runtime variables
_VERBOSE="false"

##############################################################################
# Helper Functions
##############################################################################

infomsg() {
  echo "[INFO] ${1}"
}

errormsg() {
  echo "[ERROR] ${1}" >&2
}

debug() {
  if [ "${_VERBOSE}" == "true" ]; then
    echo "[DEBUG] ${1}"
  fi
}

warnmsg() {
  echo "[WARN] ${1}" >&2
}

wait_for_condition() {
  local resource_type=$1
  local resource_name=$2
  local namespace=$3
  local condition=$4
  local timeout=$5
  local message=$6

  infomsg "${message}"
  if ! ${CLIENT_EXE} wait --for=${condition} ${resource_type}/${resource_name} -n ${namespace} --timeout=${timeout}s 2>/dev/null; then
    errormsg "Timeout waiting for ${resource_type}/${resource_name} to meet condition: ${condition}"
    return 1
  fi
  return 0
}

wait_for_deletion() {
  local resource_type=$1
  local resource_name=$2
  local namespace=$3
  local timeout=$4
  local message=$5

  infomsg "${message}"
  local start_time=$(date +%s)
  while ${CLIENT_EXE} get ${resource_type} ${resource_name} -n ${namespace} &>/dev/null; do
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    if [ ${elapsed} -ge ${timeout} ]; then
      errormsg "Timeout waiting for ${resource_type}/${resource_name} to be deleted"
      return 1
    fi
    debug "Waiting for ${resource_type}/${resource_name} to be deleted... (${elapsed}s)"
    sleep 5
  done
  return 0
}

##############################################################################
# Prerequisite Checking
##############################################################################

enable_user_workload_monitoring() {
  infomsg "Enabling User Workload Monitoring..."

  if ${CLIENT_EXE} get statefulset prometheus-user-workload -n openshift-user-workload-monitoring &>/dev/null 2>&1; then
    infomsg "User Workload Monitoring is already enabled"
    return 0
  fi

  if ! ${CLIENT_EXE} get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null 2>&1; then
    infomsg "Creating cluster-monitoring-config ConfigMap..."
    cat <<EOF | ${CLIENT_EXE} apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
  else
    infomsg "Updating cluster-monitoring-config ConfigMap..."
    ${CLIENT_EXE} patch configmap cluster-monitoring-config -n openshift-monitoring --type merge \
      -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}'
  fi

  infomsg "Waiting for User Workload Monitoring pods to be created (this may take 1-2 minutes)..."
  local max_wait=180
  local waited=0
  while ! ${CLIENT_EXE} get statefulset prometheus-user-workload -n openshift-user-workload-monitoring &>/dev/null 2>&1; do
    if [ ${waited} -ge ${max_wait} ]; then
      errormsg "Timeout waiting for User Workload Monitoring to be enabled"
      return 1
    fi
    debug "Waiting for prometheus-user-workload statefulset... (${waited}s)"
    sleep 5
    waited=$((waited + 5))
  done

  infomsg "Waiting for User Workload Monitoring pods to be ready..."
  ${CLIENT_EXE} wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus \
    -n openshift-user-workload-monitoring --timeout=300s || true

  infomsg "User Workload Monitoring enabled successfully"
  return 0
}

check_prerequisites() {
  debug "Checking prerequisites..."

  if ! which ${CLIENT_EXE} &>/dev/null; then
    errormsg "${CLIENT_EXE} command not found. Please install it or specify with --client-exe."
    return 1
  fi
  debug "Found ${CLIENT_EXE} at $(which ${CLIENT_EXE})"

  if ! ${CLIENT_EXE} whoami &>/dev/null; then
    errormsg "Cannot connect to cluster. Please log in with '${CLIENT_EXE} login'."
    return 1
  fi
  debug "Connected to cluster as $(${CLIENT_EXE} whoami)"

  if ! ${CLIENT_EXE} auth can-i create namespaces --all-namespaces &>/dev/null; then
    errormsg "Insufficient privileges. Cluster-admin access is required."
    return 1
  fi
  debug "Cluster-admin privileges confirmed"

  if ! ${CLIENT_EXE} get service prometheus-k8s -n openshift-monitoring &>/dev/null 2>&1; then
    errormsg "OpenShift cluster monitoring is not enabled (prometheus-k8s service not found)."
    return 1
  fi
  debug "OpenShift cluster monitoring (prometheus-k8s) is available"

  if ! ${CLIENT_EXE} get statefulset prometheus-user-workload -n openshift-user-workload-monitoring &>/dev/null 2>&1; then
    infomsg "User Workload Monitoring (UWM) is not enabled - enabling it now..."
    enable_user_workload_monitoring
    if [ $? -ne 0 ]; then
      errormsg "Failed to enable User Workload Monitoring"
      return 1
    fi
  fi
  debug "User Workload Monitoring (prometheus-user-workload) is available"

  return 0
}

##############################################################################
# Component Check Functions
##############################################################################

check_netobserv_installed() {
  if ${CLIENT_EXE} get flowcollector cluster &>/dev/null 2>&1; then
    return 0
  fi
  return 1
}

check_istio_installed() {
  if ${CLIENT_EXE} get istio default &>/dev/null 2>&1; then
    return 0
  fi
  if ${CLIENT_EXE} get deployment istiod -n istio-system &>/dev/null 2>&1; then
    return 0
  fi
  return 1
}

check_kiali_installed() {
  if ${CLIENT_EXE} get deployment kiali -n ${KIALI_NAMESPACE} &>/dev/null 2>&1; then
    return 0
  fi
  return 1
}

check_bookinfo_installed() {
  if ${CLIENT_EXE} get namespace ${BOOKINFO_NAMESPACE} &>/dev/null 2>&1; then
    if ${CLIENT_EXE} get deployment productpage-v1 -n ${BOOKINFO_NAMESPACE} &>/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

##############################################################################
# NetObserv Installation
##############################################################################

install_netobserv() {
  infomsg "Installing Network Observability operator (metrics-only mode)..."

  # Create namespace
  if ! ${CLIENT_EXE} get namespace openshift-netobserv-operator &>/dev/null 2>&1; then
    infomsg "Creating namespace: openshift-netobserv-operator"
    ${CLIENT_EXE} create namespace openshift-netobserv-operator
  fi

  # Create OperatorGroup and Subscription
  if ! ${CLIENT_EXE} get subscription netobserv-operator -n openshift-netobserv-operator &>/dev/null 2>&1; then
    infomsg "Creating OperatorGroup and Subscription..."
    cat <<EOF | ${CLIENT_EXE} apply -f -
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
  else
    infomsg "NetObserv Subscription already exists"
  fi

  # Wait for the CSV to appear and succeed
  infomsg "Waiting for NetObserv operator CSV to be installed..."
  local start_time=$(date +%s)
  local csv_name=""
  while [ -z "${csv_name}" ]; do
    csv_name=$(${CLIENT_EXE} get csv -n openshift-netobserv-operator -o jsonpath='{.items[?(@.spec.displayName=="NetObserv Operator")].metadata.name}' 2>/dev/null || true)
    if [ -z "${csv_name}" ]; then
      csv_name=$(${CLIENT_EXE} get csv -n openshift-netobserv-operator -o jsonpath='{.items[?(@.spec.displayName=="Network Observability")].metadata.name}' 2>/dev/null || true)
    fi
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    if [ ${elapsed} -ge ${TIMEOUT} ]; then
      errormsg "Timeout waiting for NetObserv CSV to appear"
      return 1
    fi
    if [ -z "${csv_name}" ]; then
      debug "Waiting for NetObserv CSV to appear... (${elapsed}s)"
      sleep 10
    fi
  done

  infomsg "Found CSV: ${csv_name}"
  wait_for_condition "csv" "${csv_name}" "openshift-netobserv-operator" \
    "jsonpath={.status.phase}=Succeeded" "${TIMEOUT}" \
    "Waiting for CSV to reach Succeeded phase..."

  # Wait for the FlowCollector CRD to be available
  infomsg "Waiting for FlowCollector CRD to be available..."
  local waited=0
  while ! ${CLIENT_EXE} get crd flowcollectors.flows.netobserv.io &>/dev/null 2>&1; do
    if [ ${waited} -ge 120 ]; then
      errormsg "Timeout waiting for FlowCollector CRD"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done

  # Create FlowCollector in metrics-only mode
  if ! ${CLIENT_EXE} get flowcollector cluster &>/dev/null 2>&1; then
    infomsg "Creating FlowCollector (metrics-only, Loki disabled)..."
    cat <<EOF | ${CLIENT_EXE} apply -f -
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
  else
    infomsg "FlowCollector already exists"
  fi

  # Wait for processor pods
  infomsg "Waiting for NetObserv processor pods to be ready..."
  local waited=0
  while ! ${CLIENT_EXE} get deployment flowlogs-pipeline -n netobserv &>/dev/null 2>&1; do
    if [ ${waited} -ge 120 ]; then
      warnmsg "flowlogs-pipeline deployment not found yet, continuing..."
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if ${CLIENT_EXE} get deployment flowlogs-pipeline -n netobserv &>/dev/null 2>&1; then
    ${CLIENT_EXE} wait --for=condition=available deployment/flowlogs-pipeline \
      -n netobserv --timeout=120s 2>/dev/null || true
  fi

  infomsg "NetObserv installed successfully (metrics-only mode)"
}

uninstall_netobserv() {
  infomsg "Uninstalling Network Observability..."

  # Delete FlowCollector
  ${CLIENT_EXE} delete flowcollector cluster --ignore-not-found 2>/dev/null || true

  # Wait for netobserv namespace resources to be cleaned up
  if ${CLIENT_EXE} get namespace netobserv &>/dev/null 2>&1; then
    infomsg "Waiting for NetObserv resources to be cleaned up..."
    sleep 10
  fi

  # Delete Subscription
  ${CLIENT_EXE} delete subscription netobserv-operator -n openshift-netobserv-operator --ignore-not-found 2>/dev/null || true

  # Delete CSV
  local csv_name=$(${CLIENT_EXE} get csv -n openshift-netobserv-operator -o name 2>/dev/null | head -1)
  if [ -n "${csv_name}" ]; then
    infomsg "Deleting CSV: ${csv_name}"
    ${CLIENT_EXE} delete ${csv_name} -n openshift-netobserv-operator --ignore-not-found 2>/dev/null || true
  fi

  # Delete OperatorGroup
  ${CLIENT_EXE} delete operatorgroup netobserv-operator-group -n openshift-netobserv-operator --ignore-not-found 2>/dev/null || true

  # Delete namespaces
  ${CLIENT_EXE} delete namespace netobserv --ignore-not-found --wait=false 2>/dev/null || true
  ${CLIENT_EXE} delete namespace netobserv-privileged --ignore-not-found --wait=false 2>/dev/null || true
  ${CLIENT_EXE} delete namespace openshift-netobserv-operator --ignore-not-found --wait=false 2>/dev/null || true

  # Delete CRDs
  ${CLIENT_EXE} delete crd flowcollectors.flows.netobserv.io --ignore-not-found 2>/dev/null || true
  ${CLIENT_EXE} delete crd flowmetrics.flows.netobserv.io --ignore-not-found 2>/dev/null || true

  infomsg "NetObserv uninstalled successfully"
}

status_netobserv() {
  infomsg "Checking Network Observability status..."
  echo ""

  echo "=== NetObserv Operator ==="
  if ${CLIENT_EXE} get namespace openshift-netobserv-operator &>/dev/null 2>&1; then
    echo "Namespace: openshift-netobserv-operator [EXISTS]"
    ${CLIENT_EXE} get pods -n openshift-netobserv-operator 2>/dev/null || echo "  No pods"
  else
    echo "Namespace: openshift-netobserv-operator [NOT FOUND]"
  fi

  echo ""
  echo "=== FlowCollector ==="
  ${CLIENT_EXE} get flowcollector cluster 2>/dev/null || echo "  FlowCollector not found"

  echo ""
  echo "=== NetObserv Pods ==="
  if ${CLIENT_EXE} get namespace netobserv &>/dev/null 2>&1; then
    ${CLIENT_EXE} get pods -n netobserv 2>/dev/null || echo "  No pods in netobserv namespace"
  else
    echo "  netobserv namespace not found"
  fi

  if ${CLIENT_EXE} get namespace netobserv-privileged &>/dev/null 2>&1; then
    ${CLIENT_EXE} get pods -n netobserv-privileged 2>/dev/null || echo "  No pods in netobserv-privileged namespace"
  fi
}

##############################################################################
# Istio Installation
##############################################################################

fix_istio_system_namespace() {
  # The istio-system namespace may have the openshift.io/cluster-monitoring=true
  # label, which prevents the user-workload Prometheus from picking up
  # ServiceMonitors there. The platform Prometheus claims the namespace but
  # lacks RBAC for endpoint discovery, causing a silent failure.
  if ${CLIENT_EXE} get namespace istio-system -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null | grep -q "true"; then
    infomsg "Removing openshift.io/cluster-monitoring label from istio-system..."
    ${CLIENT_EXE} label namespace istio-system openshift.io/cluster-monitoring-
    infomsg "User-workload Prometheus will now handle ServiceMonitors in istio-system"
  else
    debug "istio-system does not have openshift.io/cluster-monitoring=true label"
  fi
}

create_istio_podmonitor() {
  local namespace="$1"

  if ! ${CLIENT_EXE} get namespace "${namespace}" &>/dev/null 2>&1; then
    debug "Namespace ${namespace} not found, skipping PodMonitor creation"
    return 0
  fi

  local mesh_id=""
  local mesh_cfg="$(${CLIENT_EXE} -n istio-system get configmap istio -o jsonpath='{.data.mesh}' 2>/dev/null || true)"
  if [ -n "${mesh_cfg}" ]; then
    mesh_id="$(printf '%s\n' "${mesh_cfg}" | sed -n -E 's/^[[:space:]]*meshId:[[:space:]]*"?([^"]+)"?$/\1/p' | head -n 1)"
    if [ -z "${mesh_id}" ]; then
      mesh_id="$(printf '%s\n' "${mesh_cfg}" | sed -n -E 's/^[[:space:]]*ISTIO_META_MESH_ID:[[:space:]]*"?([^"]+)"?$/\1/p' | head -n 1)"
    fi
    if [ -z "${mesh_id}" ]; then
      mesh_id="$(printf '%s\n' "${mesh_cfg}" | sed -n -E 's/^trustDomain:[[:space:]]*"?([^"]+)"?$/\1/p' | head -n 1)"
    fi
  fi
  if [ -z "${mesh_id}" ]; then
    mesh_id="cluster.local"
  fi

  infomsg "Creating PodMonitor for Istio proxies in namespace: ${namespace}"
  cat <<EOF | ${CLIENT_EXE} apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istio-proxies-monitor
  namespace: ${namespace}
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
      replacement: '[\$2]:\$1'
      sourceLabels: ["__meta_kubernetes_pod_annotation_prometheus_io_port","__meta_kubernetes_pod_ip"]
      targetLabel: "__address__"
    - action: replace
      regex: (\d+);((([0-9]+?)(\.|$)){4})
      replacement: '\$2:\$1'
      sourceLabels: ["__meta_kubernetes_pod_annotation_prometheus_io_port","__meta_kubernetes_pod_ip"]
      targetLabel: "__address__"
    - sourceLabels: ["__meta_kubernetes_pod_label_app_kubernetes_io_name","__meta_kubernetes_pod_label_app"]
      separator: ";"
      targetLabel: "app"
      action: replace
      regex: "(.+);.*|.*;(.+)"
      replacement: "\${1}\${2}"
    - sourceLabels: ["__meta_kubernetes_pod_label_app_kubernetes_io_version","__meta_kubernetes_pod_label_version"]
      separator: ";"
      targetLabel: "version"
      action: replace
      regex: "(.+);.*|.*;(.+)"
      replacement: "\${1}\${2}"
    - sourceLabels: ["__meta_kubernetes_namespace"]
      action: replace
      targetLabel: namespace
    - action: replace
      replacement: "${mesh_id}"
      targetLabel: mesh_id
EOF
}

install_istio() {
  infomsg "Installing Istio via Sail Operator..."

  if [ ! -f "${SCRIPT_DIR}/istio/install-istio-via-sail.sh" ]; then
    errormsg "Istio installation script not found at ${SCRIPT_DIR}/istio/install-istio-via-sail.sh"
    return 1
  fi

  "${SCRIPT_DIR}/istio/install-istio-via-sail.sh" --addons "" --set '.spec.values.pilot.autoscaleEnabled = false'
  if [ $? -ne 0 ]; then
    errormsg "Istio installation failed"
    return 1
  fi

  infomsg "Istio installed successfully"

  # On OpenShift, the Istio CNI plugin is required even for sidecar mode because
  # the sidecar injector annotates pods with k8s.v1.cni.cncf.io/networks=istio-cni,
  # which Multus resolves via a NetworkAttachmentDefinition. Without IstioCNI, pods
  # fail to start with "cannot find a network-attachment-definition (istio-cni)".
  # The install-istio-via-sail.sh script only creates IstioCNI for ambient mode,
  # so we create it here for sidecar mode on OpenShift.
  if ! ${CLIENT_EXE} get istiocni default &>/dev/null 2>&1; then
    infomsg "Creating IstioCNI for OpenShift (required for Multus CNI integration)..."
    ${CLIENT_EXE} create namespace istio-cni 2>/dev/null || true
    cat <<EOF | ${CLIENT_EXE} apply -f -
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  namespace: istio-cni
EOF
    infomsg "Waiting for IstioCNI DaemonSet to be ready..."
    local waited=0
    while ! ${CLIENT_EXE} get daemonset -n istio-cni -l app=istio-cni-node &>/dev/null 2>&1; do
      if [ ${waited} -ge 60 ]; then
        warnmsg "IstioCNI DaemonSet not found after 60s, continuing..."
        break
      fi
      sleep 5
      waited=$((waited + 5))
    done
    ${CLIENT_EXE} rollout status daemonset -l app=istio-cni-node -n istio-cni --timeout=120s 2>/dev/null || true
  else
    infomsg "IstioCNI already exists"
  fi

  # Fix namespace label so user-workload Prometheus can handle ServiceMonitors
  fix_istio_system_namespace

  # Create ServiceMonitor for istiod
  infomsg "Creating ServiceMonitor for istiod..."
  cat <<EOF | ${CLIENT_EXE} apply -f -
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

  # Create PodMonitor for istio-system proxies
  infomsg "Creating PodMonitor for istio-system..."
  create_istio_podmonitor "istio-system"

  infomsg "======================================"
  infomsg "Istio installation complete!"
  infomsg "======================================"
}

uninstall_istio() {
  infomsg "Uninstalling Istio (Sail Operator)..."

  # Delete metrics monitoring resources
  infomsg "Deleting Istio metrics monitors..."
  ${CLIENT_EXE} delete servicemonitor istiod-monitor -n istio-system --ignore-not-found 2>/dev/null || true
  ${CLIENT_EXE} delete podmonitor istio-proxies-monitor -n istio-system --ignore-not-found 2>/dev/null || true

  # Delete Sail Operator CRs
  infomsg "Deleting Istio CR..."
  ${CLIENT_EXE} delete istio default --ignore-not-found 2>/dev/null || true

  infomsg "Deleting IstioCNI CR..."
  ${CLIENT_EXE} delete istiocni default --ignore-not-found 2>/dev/null || true

  # Wait for Sail Operator to clean up
  infomsg "Waiting for Sail Operator to clean up resources..."
  sleep 15

  # Uninstall Sail Operator via Helm
  infomsg "Uninstalling Sail Operator..."
  helm uninstall sail-operator -n sail-operator 2>/dev/null || true

  # Delete namespaces
  infomsg "Deleting Istio namespaces..."
  ${CLIENT_EXE} delete namespace istio-system --ignore-not-found --wait=false 2>/dev/null || true
  ${CLIENT_EXE} delete namespace istio-cni --ignore-not-found --wait=false 2>/dev/null || true
  ${CLIENT_EXE} delete namespace sail-operator --ignore-not-found --wait=false 2>/dev/null || true

  # Clean up CRDs
  infomsg "Cleaning up Sail Operator CRDs..."
  ${CLIENT_EXE} delete crd istios.sailoperator.io --ignore-not-found 2>/dev/null || true
  ${CLIENT_EXE} delete crd istiocnis.sailoperator.io --ignore-not-found 2>/dev/null || true
  ${CLIENT_EXE} delete crd istiorevisions.sailoperator.io --ignore-not-found 2>/dev/null || true
  ${CLIENT_EXE} delete crd istiorevisiontags.sailoperator.io --ignore-not-found 2>/dev/null || true

  infomsg "Cleaning up Istio CRDs..."
  ${CLIENT_EXE} get crd -o name 2>/dev/null | grep -E "\.istio\.io" | xargs -r ${CLIENT_EXE} delete --ignore-not-found 2>/dev/null || true

  infomsg "Cleaning up GatewayClasses..."
  ${CLIENT_EXE} delete gatewayclass istio istio-remote istio-waypoint --ignore-not-found 2>/dev/null || true

  infomsg "Cleaning up istio-ca ConfigMaps..."
  for ns in $(${CLIENT_EXE} get cm -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>/dev/null | grep -E "istio-ca-root-cert|istio-ca-crl" | awk '{print $1}' | sort -u); do
    ${CLIENT_EXE} delete cm istio-ca-root-cert istio-ca-crl -n "$ns" --ignore-not-found 2>/dev/null || true
  done

  ${CLIENT_EXE} get crd -o name 2>/dev/null | grep -E "\.gateway\.networking\.k8s\.io" | xargs -r ${CLIENT_EXE} delete --ignore-not-found 2>/dev/null || true

  infomsg "Istio uninstalled successfully"
}

status_istio() {
  infomsg "Checking Istio status (Sail Operator)..."
  echo ""

  echo "=== Sail Operator ==="
  if ${CLIENT_EXE} get namespace sail-operator &>/dev/null 2>&1; then
    echo "Namespace: sail-operator [EXISTS]"
    ${CLIENT_EXE} get pods -n sail-operator 2>/dev/null || echo "  No pods"
  else
    echo "Namespace: sail-operator [NOT FOUND]"
  fi

  echo ""
  echo "=== Istio CR ==="
  ${CLIENT_EXE} get istio default 2>/dev/null || echo "  Istio CR not found"

  echo ""
  echo "=== istio-system Namespace ==="
  if ${CLIENT_EXE} get namespace istio-system &>/dev/null 2>&1; then
    echo "Namespace: istio-system [EXISTS]"
    local cluster_mon=$(${CLIENT_EXE} get namespace istio-system -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null)
    if [ "${cluster_mon}" == "true" ]; then
      echo "  WARNING: openshift.io/cluster-monitoring=true (ServiceMonitors may not work)"
    else
      echo "  openshift.io/cluster-monitoring label: removed (user-workload Prometheus active)"
    fi
    ${CLIENT_EXE} get pods -n istio-system 2>/dev/null || echo "  No pods"
  else
    echo "Namespace: istio-system [NOT FOUND]"
  fi

  echo ""
  echo "=== Istio Metrics Monitors ==="
  ${CLIENT_EXE} get servicemonitor istiod-monitor -n istio-system 2>/dev/null || echo "  istiod-monitor ServiceMonitor not found"
  ${CLIENT_EXE} get podmonitor istio-proxies-monitor -n istio-system 2>/dev/null || echo "  istio-proxies-monitor PodMonitor not found"
}

##############################################################################
# Bookinfo Installation
##############################################################################

install_bookinfo() {
  infomsg "Installing Bookinfo demo application..."

  if [ ! -f "${SCRIPT_DIR}/istio/install-bookinfo-demo.sh" ]; then
    errormsg "Bookinfo install script not found at ${SCRIPT_DIR}/istio/install-bookinfo-demo.sh"
    return 1
  fi

  "${SCRIPT_DIR}/istio/install-bookinfo-demo.sh" -c "${CLIENT_EXE}" -tg --mongo
  if [ $? -ne 0 ]; then
    errormsg "Bookinfo installation failed"
    return 1
  fi

  # Create PodMonitor for Istio proxies in the bookinfo namespace
  infomsg "Creating PodMonitor for Istio proxies in ${BOOKINFO_NAMESPACE}..."
  create_istio_podmonitor "${BOOKINFO_NAMESPACE}"

  infomsg "======================================"
  infomsg "Bookinfo installed successfully"
  infomsg "======================================"
}

uninstall_bookinfo() {
  infomsg "Uninstalling Bookinfo..."

  # Delete PodMonitor
  ${CLIENT_EXE} delete podmonitor istio-proxies-monitor -n ${BOOKINFO_NAMESPACE} --ignore-not-found 2>/dev/null || true

  # Use the existing uninstall script if available
  if [ -f "${SCRIPT_DIR}/istio/install-bookinfo-demo.sh" ]; then
    "${SCRIPT_DIR}/istio/install-bookinfo-demo.sh" -c "${CLIENT_EXE}" --delete-bookinfo true
  else
    ${CLIENT_EXE} delete namespace ${BOOKINFO_NAMESPACE} --ignore-not-found --wait=false 2>/dev/null || true
  fi

  infomsg "Bookinfo uninstalled successfully"
}

##############################################################################
# Kiali Installation
##############################################################################

install_kiali() {
  infomsg "Installing Kiali (dev build) with OpenShift Prometheus integration..."

  if [ ! -d "${KIALI_REPO_DIR}" ]; then
    errormsg "Kiali repository directory not found: ${KIALI_REPO_DIR}"
    return 1
  fi

  # Locate helm binary
  local helm_exe="${HELM:-$(which helm 2>/dev/null)}"
  if [ -z "${helm_exe}" ]; then
    errormsg "helm not found. Install helm or set HELM=/path/to/helm"
    return 1
  fi
  infomsg "Using helm: ${helm_exe}"

  # Build and deploy Kiali
  pushd "${KIALI_REPO_DIR}" > /dev/null
  if [ "${SKIP_BUILD}" == "true" ]; then
    infomsg "Skipping build (--skip-build specified)..."
    HELM="${helm_exe}" \
    HELM_CHARTS_REPO_PULL=false \
    AUTH_STRATEGY=anonymous \
    CLUSTER_TYPE=openshift \
      make cluster-push operator-create kiali-create
  else
    infomsg "Building and deploying Kiali (this may take several minutes)..."
    HELM="${helm_exe}" \
    HELM_CHARTS_REPO_PULL=false \
    AUTH_STRATEGY=anonymous \
    CLUSTER_TYPE=openshift \
      make clean build-ui build cluster-push operator-create kiali-create
  fi
  if [ $? -ne 0 ]; then
    popd > /dev/null
    errormsg "Kiali build/deploy failed"
    return 1
  fi
  popd > /dev/null

  # Wait for Kiali pod to be ready
  infomsg "Waiting for Kiali deployment to be ready..."
  local waited=0
  while ! ${CLIENT_EXE} get deployment kiali -n ${KIALI_NAMESPACE} &>/dev/null 2>&1; do
    if [ ${waited} -ge 120 ]; then
      errormsg "Timeout waiting for Kiali deployment to appear"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  ${CLIENT_EXE} wait --for=condition=available deployment/kiali -n ${KIALI_NAMESPACE} --timeout=300s

  # Determine the Kiali service account name
  local kiali_sa=$(${CLIENT_EXE} get sa -n ${KIALI_NAMESPACE} -o name 2>/dev/null | grep kiali | head -1 | sed 's|serviceaccount/||')
  if [ -z "${kiali_sa}" ]; then
    kiali_sa="kiali-service-account"
    warnmsg "Could not detect Kiali SA name, defaulting to ${kiali_sa}"
  fi
  infomsg "Kiali service account: ${kiali_sa}"

  # Grant monitoring access
  infomsg "Granting cluster-monitoring-view to Kiali service account..."
  ${CLIENT_EXE} adm policy add-cluster-role-to-user cluster-monitoring-view \
    "system:serviceaccount:${KIALI_NAMESPACE}:${kiali_sa}"

  # Determine the Kiali CR namespace (where the operator created it)
  local kiali_cr_ns=""
  for ns in kiali-operator ${KIALI_NAMESPACE}; do
    if ${CLIENT_EXE} get kiali kiali -n ${ns} &>/dev/null 2>&1; then
      kiali_cr_ns="${ns}"
      break
    fi
  done
  if [ -z "${kiali_cr_ns}" ]; then
    errormsg "Could not find Kiali CR in kiali-operator or ${KIALI_NAMESPACE} namespace"
    return 1
  fi
  infomsg "Kiali CR found in namespace: ${kiali_cr_ns}"

  # Configure Kiali for Thanos Querier
  infomsg "Configuring Kiali to use Thanos Querier..."
  ${CLIENT_EXE} patch kiali kiali -n ${kiali_cr_ns} --type merge -p '
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

  # Wait for operator to reconcile the new configuration
  infomsg "Waiting for Kiali to restart with new configuration..."
  sleep 10
  ${CLIENT_EXE} wait --for=condition=available deployment/kiali -n ${KIALI_NAMESPACE} --timeout=300s

  # Fix namespace label (idempotent, safe to call again)
  fix_istio_system_namespace

  # Create ServiceMonitor for Kiali metrics (including kiali_health_status)
  infomsg "Creating ServiceMonitor for Kiali metrics..."
  cat <<EOF | ${CLIENT_EXE} apply -f -
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

  # Create PrometheusRule for NetObserv Network Health integration
  infomsg "Creating PrometheusRule for NetObserv Network Health alerts..."

  # Determine the Kiali route URL for links
  local kiali_url=""
  kiali_url=$(${CLIENT_EXE} get route kiali -n ${KIALI_NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -z "${kiali_url}" ]; then
    kiali_url="kiali-${KIALI_NAMESPACE}.apps-crc.testing"
    warnmsg "Could not detect Kiali route, defaulting to ${kiali_url}"
  fi

  cat <<EOF | ${CLIENT_EXE} apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kiali-health-alerts
  namespace: ${KIALI_NAMESPACE}
  labels:
    netobserv: "true"
spec:
  groups:
  - name: KialiHealthAlerts
    rules:
    - alert: KialiWorkloadUnhealthy
      annotations:
        netobserv_io_network_health: '{"workloadLabels":["name"],"namespaceLabels":["exported_namespace"],"kindLabels":["kind"],"threshold":"25","unit":"%","upperBound":"100","links":[{"name":"Inspect Kiali console","url":"https://${kiali_url}/console/overview"}]}'
        description: >-
          Kiali reports workload {{ \$labels.name }} in namespace
          {{ \$labels.exported_namespace }} has been unhealthy for more than
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

  infomsg "======================================"
  infomsg "Kiali installed successfully!"
  infomsg "======================================"
  infomsg ""
  infomsg "Kiali is configured to:"
  infomsg "  - Query Thanos Querier for Istio metrics"
  infomsg "  - Export kiali_health_status metric via ServiceMonitor"
  infomsg "  - Surface health alerts on NetObserv Network Health page"
  infomsg ""
  infomsg "The kiali_health_status metric should appear in Prometheus"
  infomsg "within 1-2 minutes. Check via: Observe -> Metrics in the"
  infomsg "OpenShift console, querying: kiali_health_status"
  infomsg ""
  infomsg "Health alerts will appear on the NetObserv Network Health"
  infomsg "page under the Workloads tab once workloads are unhealthy"
  infomsg "for >25% of the past 10 minutes."
}

uninstall_kiali() {
  infomsg "Uninstalling Kiali..."

  # Delete PrometheusRule and ServiceMonitor
  ${CLIENT_EXE} delete prometheusrule kiali-health-alerts -n ${KIALI_NAMESPACE} --ignore-not-found 2>/dev/null || true
  ${CLIENT_EXE} delete servicemonitor kiali-monitor -n istio-system --ignore-not-found 2>/dev/null || true

  # Remove ClusterRoleBinding
  local kiali_sa=$(${CLIENT_EXE} get sa -n ${KIALI_NAMESPACE} -o name 2>/dev/null | grep kiali | head -1 | sed 's|serviceaccount/||')
  if [ -n "${kiali_sa}" ]; then
    ${CLIENT_EXE} adm policy remove-cluster-role-from-user cluster-monitoring-view \
      "system:serviceaccount:${KIALI_NAMESPACE}:${kiali_sa}" 2>/dev/null || true
  fi

  # Use make targets to uninstall
  pushd "${KIALI_REPO_DIR}" > /dev/null
  CLUSTER_TYPE=openshift make kiali-delete 2>/dev/null || true
  CLUSTER_TYPE=openshift make operator-delete 2>/dev/null || true
  popd > /dev/null

  # Clean up remaining resources
  ${CLIENT_EXE} delete namespace kiali-operator --ignore-not-found --wait=false 2>/dev/null || true

  infomsg "Kiali uninstalled successfully"
}

status_kiali() {
  infomsg "Checking Kiali status..."
  echo ""

  echo "=== Kiali Operator ==="
  if ${CLIENT_EXE} get namespace kiali-operator &>/dev/null 2>&1; then
    echo "Namespace: kiali-operator [EXISTS]"
    ${CLIENT_EXE} get pods -n kiali-operator 2>/dev/null || echo "  No pods"
  else
    echo "Namespace: kiali-operator [NOT FOUND]"
  fi

  echo ""
  echo "=== Kiali CR ==="
  for ns in kiali-operator ${KIALI_NAMESPACE}; do
    if ${CLIENT_EXE} get kiali kiali -n ${ns} &>/dev/null 2>&1; then
      echo "  Kiali CR found in namespace: ${ns}"
      ${CLIENT_EXE} get kiali kiali -n ${ns} -o jsonpath='{.status.conditions[0].type}: {.status.conditions[0].status}' 2>/dev/null
      echo ""
      break
    fi
  done

  echo ""
  echo "=== Kiali Deployment ==="
  if ${CLIENT_EXE} get deployment kiali -n ${KIALI_NAMESPACE} &>/dev/null 2>&1; then
    ${CLIENT_EXE} get deployment kiali -n ${KIALI_NAMESPACE}
  else
    echo "  Kiali deployment not found in ${KIALI_NAMESPACE}"
  fi

  echo ""
  echo "=== Kiali Metrics Monitor ==="
  ${CLIENT_EXE} get servicemonitor kiali-monitor -n istio-system 2>/dev/null || echo "  kiali-monitor ServiceMonitor not found"

  echo ""
  echo "=== NetObserv Health Alerts ==="
  ${CLIENT_EXE} get prometheusrule kiali-health-alerts -n ${KIALI_NAMESPACE} 2>/dev/null || echo "  kiali-health-alerts PrometheusRule not found"

  echo ""
  echo "=== Prometheus Targets ==="
  if ${CLIENT_EXE} get pod prometheus-user-workload-0 -n openshift-user-workload-monitoring &>/dev/null 2>&1; then
    local kiali_targets=$(${CLIENT_EXE} exec -n openshift-user-workload-monitoring prometheus-user-workload-0 \
      -c prometheus -- curl -s 'http://localhost:9090/api/v1/targets?scrapePool=serviceMonitor/istio-system/kiali-monitor/0' 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'  {t[\"scrapeUrl\"]}: {t[\"health\"]}') for t in d.get('data',{}).get('activeTargets',[])]" 2>/dev/null || echo "  Could not query Prometheus targets")
  else
    echo "  User-workload Prometheus not available"
  fi
}

##############################################################################
# Combined Status
##############################################################################

status_all() {
  status_netobserv
  echo ""
  echo "================================================================"
  echo ""
  status_istio
  echo ""
  echo "================================================================"
  echo ""

  echo "=== Bookinfo ==="
  if check_bookinfo_installed; then
    echo "Bookinfo: INSTALLED"
    ${CLIENT_EXE} get pods -n ${BOOKINFO_NAMESPACE} 2>/dev/null || echo "  No pods"
    echo ""
    echo "PodMonitor:"
    ${CLIENT_EXE} get podmonitor istio-proxies-monitor -n ${BOOKINFO_NAMESPACE} 2>/dev/null || echo "  Not found"
  else
    echo "Bookinfo: NOT INSTALLED"
  fi

  echo ""
  echo "================================================================"
  echo ""
  status_kiali

  echo ""
  echo "================================================================"
  echo ""
  echo "=== User Workload Monitoring ==="
  if ${CLIENT_EXE} get statefulset prometheus-user-workload -n openshift-user-workload-monitoring &>/dev/null 2>&1; then
    echo "Status: ENABLED"
    ${CLIENT_EXE} get pods -n openshift-user-workload-monitoring 2>/dev/null
  else
    echo "Status: NOT ENABLED"
  fi
}

##############################################################################
# Uber Commands
##############################################################################

install_all() {
  infomsg "======================================"
  infomsg "Installing complete NetObserv + Kiali environment"
  infomsg "======================================"
  infomsg ""
  infomsg "This will run the following steps in sequence:"
  infomsg "  1. Enable User Workload Monitoring"
  infomsg "  2. Install NetObserv (metrics-only)"
  infomsg "  3. Install Istio (Sail Operator)"
  infomsg "  4. Install Bookinfo demo app"
  infomsg "  5. Install Kiali (dev build)"
  infomsg ""

  local total_steps=5
  local step=1

  # Step 1: UWM
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Enabling User Workload Monitoring"
  infomsg "======================================"
  check_prerequisites || exit 2
  step=$((step + 1))

  # Step 2: NetObserv
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Installing NetObserv"
  infomsg "======================================"
  install_netobserv
  if [ $? -ne 0 ]; then
    errormsg "Failed to install NetObserv"
    return 1
  fi
  step=$((step + 1))

  # Step 3: Istio
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Installing Istio"
  infomsg "======================================"
  install_istio
  if [ $? -ne 0 ]; then
    errormsg "Failed to install Istio"
    return 1
  fi
  step=$((step + 1))

  # Step 4: Bookinfo
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Installing Bookinfo"
  infomsg "======================================"
  install_bookinfo
  if [ $? -ne 0 ]; then
    errormsg "Failed to install Bookinfo"
    return 1
  fi
  step=$((step + 1))

  # Step 5: Kiali
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Installing Kiali"
  infomsg "======================================"
  install_kiali
  if [ $? -ne 0 ]; then
    errormsg "Failed to install Kiali"
    return 1
  fi

  infomsg ""
  infomsg "======================================"
  infomsg "Environment setup complete!"
  infomsg "======================================"
  infomsg ""
  infomsg "All components installed:"
  infomsg "  - User Workload Monitoring: enabled"
  infomsg "  - NetObserv: metrics-only mode (no Loki)"
  infomsg "  - Istio: Sail Operator"
  infomsg "  - Bookinfo: with traffic generator"
  infomsg "  - Kiali: dev build, querying Thanos Querier"
  infomsg ""
  infomsg "Metrics available in Prometheus:"
  infomsg "  - istio_requests_total (Istio traffic metrics)"
  infomsg "  - kiali_health_status (Kiali health precompute)"
  infomsg ""
  infomsg "NetObserv Network Health integration:"
  infomsg "  - PrometheusRule kiali-health-alerts created"
  infomsg "  - Alerts appear under the Workloads tab"
  infomsg "  - Alerts fire when workloads are unhealthy >25% of past 10 min"
}

install_components() {
  infomsg "======================================"
  infomsg "Installing missing components on existing cluster"
  infomsg "======================================"
  infomsg ""

  local total_steps=5
  local step=1

  # Step 1: Prerequisites / UWM
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Checking prerequisites"
  infomsg "======================================"
  check_prerequisites || exit 2
  step=$((step + 1))

  # Step 2: NetObserv
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Checking/Installing NetObserv"
  infomsg "======================================"
  if check_netobserv_installed; then
    infomsg "NetObserv is already installed - skipping"
  else
    infomsg "NetObserv not found - installing..."
    install_netobserv
    if [ $? -ne 0 ]; then
      errormsg "Failed to install NetObserv"
      return 1
    fi
  fi
  step=$((step + 1))

  # Step 3: Istio
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Checking/Installing Istio"
  infomsg "======================================"
  if check_istio_installed; then
    infomsg "Istio is already installed - skipping"
    # Still fix the namespace label in case it wasn't done
    fix_istio_system_namespace
  else
    infomsg "Istio not found - installing..."
    install_istio
    if [ $? -ne 0 ]; then
      errormsg "Failed to install Istio"
      return 1
    fi
  fi
  step=$((step + 1))

  # Step 4: Bookinfo
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Checking/Installing Bookinfo"
  infomsg "======================================"
  if check_bookinfo_installed; then
    infomsg "Bookinfo is already installed - skipping"
  else
    infomsg "Bookinfo not found - installing..."
    install_bookinfo
    if [ $? -ne 0 ]; then
      errormsg "Failed to install Bookinfo"
      return 1
    fi
  fi
  step=$((step + 1))

  # Step 5: Kiali
  infomsg ""
  infomsg "======================================"
  infomsg "Step ${step}/${total_steps}: Checking/Installing Kiali"
  infomsg "======================================"
  if check_kiali_installed; then
    infomsg "Kiali is already installed - skipping"
  else
    infomsg "Kiali not found - installing..."
    install_kiali
    if [ $? -ne 0 ]; then
      errormsg "Failed to install Kiali"
      return 1
    fi
  fi

  infomsg ""
  infomsg "======================================"
  infomsg "All components are installed!"
  infomsg "======================================"
}

##############################################################################
# Argument Parsing
##############################################################################

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    install-all|install-components|install-netobserv|uninstall-netobserv|status-netobserv|install-istio|uninstall-istio|status-istio|install-bookinfo|uninstall-bookinfo|install-kiali|uninstall-kiali|status-kiali|status)
      _CMD="${key}"
      shift
      ;;
    -ce|--client-exe)
      CLIENT_EXE="$2"
      shift;shift
      ;;
    -t|--timeout)
      TIMEOUT="$2"
      shift;shift
      ;;
    -kn|--kiali-namespace)
      KIALI_NAMESPACE="$2"
      shift;shift
      ;;
    -bn|--bookinfo-namespace)
      BOOKINFO_NAMESPACE="$2"
      shift;shift
      ;;
    -krd|--kiali-repo-dir)
      KIALI_REPO_DIR="$2"
      shift;shift
      ;;
    -sb|--skip-build)
      SKIP_BUILD="true"
      shift
      ;;
    -v|--verbose)
      _VERBOSE="true"
      shift
      ;;
    -h|--help)
      cat <<HELPMSG

$0 [options] command

This script sets up an OpenShift environment for testing Kiali's
kiali_health_status metric integration with NetObserv's Network Health page.

Valid options:
  -ce|--client-exe <path>
      Path to the oc executable.
      Default: ${DEFAULT_CLIENT_EXE}
  -t|--timeout <seconds>
      Timeout in seconds for waiting on resources.
      Default: ${DEFAULT_TIMEOUT}
  -kn|--kiali-namespace <namespace>
      Namespace where Kiali is deployed.
      Default: ${DEFAULT_KIALI_NAMESPACE}
  -bn|--bookinfo-namespace <namespace>
      Namespace for the Bookinfo demo app.
      Default: ${DEFAULT_BOOKINFO_NAMESPACE}
  -krd|--kiali-repo-dir <path>
      Path to the Kiali git repository (for building images).
      Default: ${DEFAULT_KIALI_REPO_DIR}
  -sb|--skip-build
      Skip building Kiali server images (use existing images).
      Default: ${DEFAULT_SKIP_BUILD}
  -v|--verbose
      Enable verbose/debug output.
  -h|--help
      Display this help message.

The command must be one of:
  install-all:          Install everything (UWM + NetObserv + Istio + Bookinfo + Kiali)
  install-components:   Install missing components on existing cluster
  install-netobserv:    Install NetObserv operator + FlowCollector (metrics-only)
  uninstall-netobserv:  Remove NetObserv
  status-netobserv:     Check NetObserv status
  install-istio:        Install Istio via Sail + configure metrics collection
  uninstall-istio:      Remove Istio
  status-istio:         Check Istio status
  install-bookinfo:     Deploy Bookinfo with traffic generator + PodMonitor
  uninstall-bookinfo:   Remove Bookinfo
  install-kiali:        Build & deploy Kiali, configure Prometheus, create ServiceMonitor
  uninstall-kiali:      Remove Kiali
  status-kiali:         Check Kiali status
  status:               Show status of all components

Examples:
  # Install everything from scratch
  $0 install-all

  # Install only missing components
  $0 install-components

  # Install individual components
  $0 install-netobserv
  $0 install-istio
  $0 install-bookinfo
  $0 install-kiali

  # Rebuild Kiali without full build
  $0 --skip-build install-kiali

  # Check status
  $0 status

  # Uninstall individual components
  $0 uninstall-kiali
  $0 uninstall-bookinfo
  $0 uninstall-istio
  $0 uninstall-netobserv

HELPMSG
      exit 0
      ;;
    *)
      errormsg "Unknown argument [$key]. Use -h for help."
      exit 1
      ;;
  esac
done

# Set defaults for unset variables
: ${CLIENT_EXE:=${DEFAULT_CLIENT_EXE}}
: ${TIMEOUT:=${DEFAULT_TIMEOUT}}
: ${KIALI_NAMESPACE:=${DEFAULT_KIALI_NAMESPACE}}
: ${BOOKINFO_NAMESPACE:=${DEFAULT_BOOKINFO_NAMESPACE}}
: ${KIALI_REPO_DIR:=${DEFAULT_KIALI_REPO_DIR}}
: ${SKIP_BUILD:=${DEFAULT_SKIP_BUILD}}

# Debug output
debug "CLIENT_EXE=${CLIENT_EXE}"
debug "TIMEOUT=${TIMEOUT}"
debug "KIALI_NAMESPACE=${KIALI_NAMESPACE}"
debug "BOOKINFO_NAMESPACE=${BOOKINFO_NAMESPACE}"
debug "KIALI_REPO_DIR=${KIALI_REPO_DIR}"
debug "SKIP_BUILD=${SKIP_BUILD}"

##############################################################################
# Main
##############################################################################

if [ -z "${_CMD}" ]; then
  errormsg "Missing command. Use -h for help."
  exit 1
fi

# Check prerequisites (skip for install-all since it handles UWM itself)
if [ "${_CMD}" != "install-all" ]; then
  check_prerequisites || exit 2
fi

# Execute command
case ${_CMD} in
  install-all)
    install_all
    ;;
  install-components)
    install_components
    ;;
  install-netobserv)
    install_netobserv
    ;;
  uninstall-netobserv)
    uninstall_netobserv
    ;;
  status-netobserv)
    status_netobserv
    ;;
  install-istio)
    install_istio
    ;;
  uninstall-istio)
    uninstall_istio
    ;;
  status-istio)
    status_istio
    ;;
  install-bookinfo)
    install_bookinfo
    ;;
  uninstall-bookinfo)
    uninstall_bookinfo
    ;;
  install-kiali)
    install_kiali
    ;;
  uninstall-kiali)
    uninstall_kiali
    ;;
  status-kiali)
    status_kiali
    ;;
  status)
    status_all
    ;;
  *)
    errormsg "Unknown command: ${_CMD}"
    exit 1
    ;;
esac
