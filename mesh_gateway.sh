#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-the-store}"
GATEWAY_NS="${GATEWAY_NS:-gateway}"
BACKEND_SVC_HINT="${BACKEND_SVC_HINT:-catalog}"   # hint to locate backend cluster in Envoy (e.g., "catalog")

cmd="${1:-install}"

# Wait for Kuma control plane, CRDs, and admission webhooks to be ready
wait_for_kuma_ready() {
  echo "[✓] Waiting for Kuma CRDs to be registered..."
  for i in {1..60}; do
    if kubectl get crd meshes.kuma.io >/dev/null 2>&1; then
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then
      echo "ERROR: meshes.kuma.io CRD not found after waiting. Is Kuma installed correctly?"
      return 1
    fi
  done

  echo "[✓] Waiting for kuma-system deployments to be available..."
  if kubectl -n kuma-system get deploy >/dev/null 2>&1; then
    kubectl -n kuma-system wait --for=condition=Available deploy --all --timeout=300s || true
  fi

  echo "[✓] Waiting for kuma-control-plane pods to be Ready..."
  kubectl -n kuma-system wait --for=condition=Ready pod -l app=kuma-control-plane --timeout=300s || true

  echo "[✓] Waiting for kuma-control-plane service endpoints..."
  for i in {1..60}; do
    if kubectl -n kuma-system get endpoints kuma-control-plane -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
      break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then
      echo "ERROR: kuma-control-plane service has no endpoints after waiting."
      return 1
    fi
  done

  echo "[✓] Probing admission webhook readiness (server-side dry-run)..."
  for i in {1..60}; do
    if kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<'YAML'
apiVersion: kuma.io/v1alpha1
kind: Mesh
metadata:
  name: readiness-check
spec: {}
YAML
    then
      echo "Admission webhooks are ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Admission webhooks did not become ready in time."
  return 1
}

apply_mesh_gateway_permissions() {
  if ! kubectl get crd meshtrafficpermissions.kuma.io >/dev/null 2>&1; then
    echo "[info] MeshTrafficPermission CRD not found (older Kuma). Skipping targetRef policies."
    return 0
  fi
  echo "[✓] Applying MeshTrafficPermission resources (targetRef model) Kong -> backends..."
  local services=("catalog" "carts" "orders" "checkout")
  for svc in "${services[@]}"; do
    # NOTE:
    # - Destination: MeshService (name + namespace) is required (no labels here).
    # - Source: Using MeshSubset with tags because 'Dataplane' kind is not supported in this Kuma version.
    #   This will emit a deprecation warning; upgrade Kuma and then switch to the newer source selector when available.
    cat <<YAML | kubectl apply -f - || echo "[warn] Failed applying MeshTrafficPermission for ${svc}; continuing"
apiVersion: kuma.io/v1alpha1
kind: MeshTrafficPermission
metadata:
  name: kong-to-${svc}
  namespace: ${GATEWAY_NS}
spec:
  targetRef:
    kind: MeshService
    name: ${svc}
    namespace: ${NAMESPACE}
  from:
    - targetRef:
        kind: MeshSubset
        tags:
          k8s.kuma.io/namespace: ${GATEWAY_NS}
          app.kubernetes.io/name: kong
      default:
        action: Allow
YAML
  done
}

install_gateway_api_crds() {
  echo "[3/10] Ensuring Gateway API CRDs are installed..."
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    echo "    Gateway API CRDs already present."
    return
  fi

  local gateway_api_url="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml"
  echo "    Installing Gateway API CRDs from ${gateway_api_url}"
  kubectl apply -f "${gateway_api_url}"

  echo "    Waiting for Gateway API CRDs to be established..."
  local crds=(
    gateways.gateway.networking.k8s.io
    gatewayclasses.gateway.networking.k8s.io
    httproutes.gateway.networking.k8s.io
    referencepolicies.gateway.networking.k8s.io
  )
  for crd in "${crds[@]}"; do
    kubectl wait --for=condition=Established "crd/${crd}" --timeout=120s >/dev/null 2>&1 || {
      echo "[warn] Timed out waiting for CRD ${crd} to be established. Continuing..."
    }
  done
}

apply_gateway_api_resources() {
  echo "[8/10] Applying Gateway API resources for Kong Gateway..."

  cat <<YAML | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kong
spec:
  controllerName: konghq.com/kic-gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kong
  namespace: ${GATEWAY_NS}
spec:
  gatewayClassName: kong
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ui
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: kong
      namespace: ${GATEWAY_NS}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: ui
          port: 80
YAML

  echo "    Waiting for Gateway/HTTPRoute status conditions..."
  kubectl wait --for=condition=Programmed gateway/kong -n "${GATEWAY_NS}" --timeout=120s >/dev/null 2>&1 || true
  kubectl wait --for=condition=Accepted httproute/ui -n "${NAMESPACE}" --timeout=120s >/dev/null 2>&1 || true
}

install_stack() {
  echo "[1/8] Adding Kuma/Kong repos with Helm..."
  helm repo add kuma https://kumahq.github.io/charts >/dev/null
  helm repo add kong https://charts.konghq.com >/dev/null
  helm repo update >/dev/null

  echo "[2/8] Installing/upgrading Kuma (standalone mode)..."
  helm upgrade --install kuma kuma/kuma \
    -n kuma-system --create-namespace \
    --set controlPlane.mode=standalone
  echo "Waiting for Kuma control plane to be ready..."
  wait_for_kuma_ready
  install_gateway_api_crds

  echo "[3/8] Enabling sidecar injection on namespaces..."
  kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label ns "${NAMESPACE}" kuma.io/sidecar-injection=enabled --overwrite || true
  kubectl create ns "${GATEWAY_NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label ns "${GATEWAY_NS}" kuma.io/sidecar-injection=enabled --overwrite || true

  echo "[4/8] Installing Kong Gateway (data-plane) as separate release 'kong-gw' (DB-less)..."

  # Provide a DB-less declarative config that routes all paths to the UI service
  cat <<YAML | kubectl -n "${GATEWAY_NS}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kong-dbless-config
data:
  kong.yml: |
    _format_version: "3.0"
    services:
      - name: ui-svc
        url: http://ui.${NAMESPACE}.svc.cluster.local:80
        routes:
          - name: ui-root
            paths:
              - "/"
            strip_path: false
            protocols: ["http"]
YAML

  cat > /tmp/values-gw.yaml <<'YAML'
ingressController:
  enabled: false
env:
  database: "off"
proxy:
  type: NodePort
admin:
  enabled: true
  http:
    enabled: true
    servicePort: 8001
  tls:
    enabled: false
podAnnotations:
  kuma.io/gateway: "enabled"
  kuma.io/transparent-proxying: "enabled"
  kuma.io/exclude-inbound-ports: "8000,8443,8001,8444"
  kuma.io/exclude-outbound-ports: "8000,8443,8001,8444"
dblessConfig:
  configMap: kong-dbless-config
  configMapKey: kong.yml
YAML

  helm upgrade --install kong-gw kong/kong \
    -n "${GATEWAY_NS}" --create-namespace \
    -f /tmp/values-gw.yaml

  # Ensure Admin service publishes not-ready addresses so any controllers/tools can connect early
  echo "[4b/8] Patching Admin service to publish not-ready addresses (breaks readiness loop)..."
  kubectl -n "${GATEWAY_NS}" patch svc kong-gw-kong-admin --type merge -p '{"spec":{"publishNotReadyAddresses":true}}' >/dev/null || true

  echo "[5/8] Skipping KIC install (DB-less mode) and Gateway API resources; Kong is configured declaratively."

  echo "[6/8] (Optional) Migrate from ingress-nginx to Kong..."
  kubectl -n ingress-nginx scale deploy ingress-nginx-controller --replicas=0 || true

  echo "[7/8] Ensure Mesh 'default' and apply minimal TrafficPermission..."
  wait_for_kuma_ready

  if ! kubectl get mesh default >/dev/null 2>&1; then
    cat <<'YAML' | kubectl apply -f -
apiVersion: kuma.io/v1alpha1
kind: Mesh
metadata:
  name: default
spec:
  mtls:
    enabledBackend: builtin
    backends:
      - name: builtin
        type: builtin
YAML
  fi

  cat <<'YAML' | kubectl apply -f -
apiVersion: kuma.io/v1alpha1
kind: TrafficPermission
mesh: default
metadata:
  name: ui-to-backends
spec:
  sources:
  - match: { kuma.io/service: ui_the-store_svc_80 }
  destinations:
  - match: { kuma.io/service: catalog_the-store_svc_80 }
  - match: { kuma.io/service: carts_the-store_svc_80 }
  - match: { kuma.io/service: orders_the-store_svc_80 }
  - match: { kuma.io/service: checkout_the-store_svc_80 }
YAML

  cat <<'YAML' | kubectl apply -f -
apiVersion: kuma.io/v1alpha1
kind: TrafficPermission
mesh: default
metadata:
  name: kong-to-backends
spec:
  sources:
    - match:
        k8s.kuma.io/namespace: gateway
  destinations:
    - match: { kuma.io/service: catalog_the-store_svc_80 }
    - match: { kuma.io/service: carts_the-store_svc_80 }
    - match: { kuma.io/service: orders_the-store_svc_80 }
    - match: { kuma.io/service: checkout_the-store_svc_80 }
YAML

  cat <<'YAML' | kubectl apply -f -
apiVersion: kuma.io/v1alpha1
kind: TrafficPermission
mesh: default
metadata:
  name: kong-to-ui
spec:
  sources:
    - match:
        k8s.kuma.io/namespace: gateway
  destinations:
    - match: { kuma.io/service: ui_the-store_svc_80 }
YAML

  apply_mesh_gateway_permissions

  echo "✔︎ Done: Kuma + Kong (DB-less declarative) installed."
  echo "   - Gateway release:   kong-gw"
  echo
  echo "Kong endpoints --------------------------------------------------------"
  echo "  Port-forward: kubectl -n gateway port-forward svc/kong-gw-kong-proxy 8080:80"
  local gateway_url
  case "$(uname -s)" in
    Darwin|CYGWIN*|MINGW*|MSYS*)
      gateway_url="http://host.docker.internal:8080"
      ;;
    *)
      gateway_url="http://127.0.0.1:8080"
      ;;
  esac
  echo "                Default base URL: ${gateway_url}"
  echo "                Linux containers: use --network host when running E2E tests"
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
  NODE_PORT=$(kubectl -n gateway get svc kong-gw-kong-proxy -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
  echo "  NodePort:     http://${NODE_IP}:${NODE_PORT}"
  echo "------------------------------------------------------------------------"
}

rollback_stack() {
  echo "[rollback] Uninstalling Kong Ingress Controller (kic) and Gateway (kong-gw)..."
  helm -n "${GATEWAY_NS}" uninstall kic || true
  helm -n "${GATEWAY_NS}" uninstall kong-gw || true

  echo "[rollback] Scaling ingress-nginx back up if present..."
  kubectl -n ingress-nginx scale deploy ingress-nginx-controller --replicas=1 2>/dev/null || true

  echo "✔ Rollback complete."
}

case "${cmd}" in
  install|"")
    install_stack
    ;;
  rollback)
    rollback_stack
    ;;
  *)
    echo "Usage: $0 [install|rollback]"
    exit 1
    ;;
esac
