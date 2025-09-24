# Service Mesh & API Gateway Guide

This guide walks you through deploying the Kuma service mesh together with the Kong API Gateway (delegated) for **The Store**, validating the routing configuration, and inspecting the gateway logs.

## Prerequisites

Make sure the following tools are installed and available in your `$PATH`:

- [Docker](https://docs.docker.com/get-docker/) running locally
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [Helm](https://helm.sh/docs/intro/install/)

> **Tip:** Run `./local.sh status` to quickly confirm that Docker, Kind, and kubectl are reachable from your terminal.

## 1. Create or reuse a Kubernetes cluster

Create the Kind cluster (or reuse an existing one) together with the baseline microservices:

```bash
   ./local.sh create-cluster
```

> The command builds all service images, loads them into the Kind cluster, deploys the manifests under `dist/kubernetes.yaml`, and runs the end-to-end smoke tests by default. 
> **If you already have the cluster and workloads running you can skip this step.**

## 2. Install Kuma and Kong

Run the mesh installer script to provision the Kuma control plane, enable sidecar injection, and install Kong in DB-less mode:

```bash
  ./mesh_gateway.sh install
```

What the script does for you:

- Adds the `kumahq` and `konghq` Helm repositories and installs Kuma in standalone mode.
- Enables automatic sidecar injection for the `the-store` (application) and `gateway` namespaces.
- Installs Kong Gateway (`kong-gw` Helm release) preconfigured to route all incoming requests to the UI service.
- Applies baseline Kuma resources (`Mesh`, `TrafficPermission`, `MeshTrafficPermission`) that allow the UI, Kong, and backend services to communicate securely.
- Prints the local access URLs (port-forward and NodePort) once the stack is ready.

> **Note:** The script is idempotent—you can rerun it to reconcile drift. To remove the mesh/gateway components use `./mesh_gateway.sh rollback`.

## 3. Access the gateway

After installation, you can expose Kong locally through port-forwarding:

```bash
  kubectl -n gateway port-forward svc/kong-gw-kong-proxy 8080:80
```

The Store UI is now reachable at <http://localhost:8080/>. Use a separate terminal to keep the port-forward active while testing.

If you prefer using the NodePort exposed by Kind, the installer output shows the URL (for example `http://127.0.0.1:32xxx`).

## 4. Test routing through the gateway

Use the provided script to send sample requests through Kong and verify that key routes return HTTP 200 responses:

```bash
  ./route-test.sh
```

The script issues `curl` requests for the storefront root page, catalog, cart, checkout, and an example product detail page. Inspect the output to confirm that each route responds successfully and returns HTML content.

You can also browse to the UI at <http://localhost:8080/> to validate end-to-end functionality manually.

Or, use the E2E test script targeting the API Gateway

```bash
  ./src/e2e/scripts/run-docker.sh --gateway http://host.docker.internal:8080
```

## 5. Monitor API Gateway logs

The repository includes a helper to tail the most relevant logs (Kong proxy, Kuma sidecar, namespace events, and the Kong Ingress Controller if present).

```bash
  ./monitor-gateway-logs.sh --namespace gateway
```

- On macOS, this opens a Terminal window with multiple tabs—one per log stream.
- On Linux, it prefers `tmux` for a split-pane experience. If `tmux` is not available, the script runs each `kubectl logs` command sequentially in the current terminal.

Use `Ctrl+C` to stop the log tailing.

If you only need the commands (for example to copy into another session), run:

```bash
  ./monitor-gateway-logs.sh --namespace gateway --print-only
```

## 6. Troubleshooting tips

- **Kuma readiness** – The installer waits for the Kuma CRDs, control plane pods, and webhooks. If it keeps timing out, inspect the control plane namespace:
```bash
  kubectl -n kuma-system get pods
  kubectl -n kuma-system logs deploy/kuma-control-plane
```
- **Gateway status** – Verify the Gateway API resources and Kong pod:
```bash
  kubectl -n gateway get gateway,httproute
  kubectl -n gateway get pods -l app.kubernetes.io/name=kong
```
- **Traffic permissions** – Ensure the expected Kuma `TrafficPermission` objects exist if requests are denied:
```bash
  kubectl get trafficpermissions.kuma.io -A
  kubectl get meshtrafficpermissions.kuma.io -n gateway
```

With these steps you can deploy, validate, and monitor the service mesh and API gateway setup that fronts The Store microservices.
