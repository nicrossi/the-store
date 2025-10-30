# Kuma Service Mesh Deployment

## Instalar Kuma (control plane)
```bash
kubectl create namespace kuma-system
helm repo add kuma https://kumahq.github.io/charts
helm repo update
helm upgrade --install kuma kuma/kuma -n kuma-system
```

Habilitar sidecar injection
```bash
kubectl label namespace the-store kuma.io/sidecar-injection=enabled
```

Aplicar políticas
```bash
kubectl apply -f deployments/kuma/mesh.yaml
kubectl apply -f deployments/kuma/traffic-permissions.yaml
kubectl apply -f deployments/kuma/retries.yaml
kubectl apply -f deployments/kuma/timeouts.yaml
```


Verificar sidecars
```bash
kubectl get pods -n the-store -o jsonpath='{.items[*].spec.containers[*].name}'
```

Debe incluir envoy junto a cada servicio.