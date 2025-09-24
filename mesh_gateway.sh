#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-the-store}"
GATEWAY_NS="${GATEWAY_NS:-gateway}"
# Mesh name to use for Kuma resources.
MESH_NAME="${MESH_NAME:-the-store}"
cmd="${1:-install}"

wait_for_kuma_ready() {
  echo "✔︎ Waiting for Kuma to be ready..."
  for i in {1..60}; do
    if kubectl get crd meshes.kuma.io >/dev/null 2>&1; then break; fi
    sleep 2
  done
  kubectl -n kuma-system wait --for=condition=Available deploy --all --timeout=300s || true
  kubectl -n kuma-system wait --for=condition=Ready pod -l app=kuma-control-plane --timeout=300s || true
}

# Ensure the target Mesh exists (defaults to ${MESH_NAME})
apply_mesh() {
  echo "✔︎ Ensuring Mesh '${MESH_NAME}' exists..."
  cat <<YAML | kubectl apply -f -
apiVersion: kuma.io/v1alpha1
kind: Mesh
metadata:
  name: ${MESH_NAME}
spec: {}
YAML
}

apply_mesh_gateway_permissions() {
  echo "✔︎ Applying MeshTrafficPermission resources..."
  for svc in catalog carts orders checkout; do
    cat <<YAML | kubectl apply -f - || echo "[warn] Failed for ${svc}"
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
  echo "✔︎ Installing Gateway API CRDs..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
  for crd in gateways.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io; do
    kubectl wait --for=condition=Established crd/${crd} --timeout=120s || true
  done
}

install_stack() {
  echo "✔︎ Installing Kuma and Kong Gateway..."
  helm repo add kuma https://kumahq.github.io/charts >/dev/null
  helm repo add kong https://charts.konghq.com >/dev/null
  helm repo update >/dev/null

  helm upgrade --install kuma kuma/kuma -n kuma-system --create-namespace --set controlPlane.mode=standalone
  wait_for_kuma_ready
  install_gateway_api_crds

  # Create target namespaces (app and gateway)
  kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create ns "${GATEWAY_NS}" --dry-run=client -o yaml | kubectl apply -f -

  # Create the Mesh and label namespaces to join it
  apply_mesh
  kubectl label ns "${NAMESPACE}" kuma.io/sidecar-injection=enabled --overwrite
  kubectl label ns "${NAMESPACE}" kuma.io/mesh="${MESH_NAME}" --overwrite
  kubectl label ns "${GATEWAY_NS}" kuma.io/sidecar-injection=enabled --overwrite
  kubectl label ns "${GATEWAY_NS}" kuma.io/mesh="${MESH_NAME}" --overwrite

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

  helm upgrade --install kong-gw kong/kong -n "${GATEWAY_NS}" --create-namespace -f - <<'YAML'
ingressController:
  enabled: false
env:
  database: "off"
proxy:
  type: NodePort
dblessConfig:
  configMap: kong-dbless-config
  configMapKey: kong.yml
YAML

  apply_mesh_gateway_permissions
  echo ""
  echo "✔︎ Kuma + Kong installed."
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
  echo "✔︎ Rolling back Kong Gateway..."
  helm -n "${GATEWAY_NS}" uninstall kong-gw || true
  kubectl -n ingress-nginx scale deploy ingress-nginx-controller --replicas=1 || true
}

case "${cmd}" in
  install) install_stack ;;
  rollback) rollback_stack ;;
  *) echo "Usage: $0 [install|rollback]" && exit 1 ;;
esac
