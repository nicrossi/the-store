# Kong API Gateway Deployment

## Namespace
```bash
  kubectl create namespace gateway
```

Instalar Kong con Helm
```bash
  helm repo add kong https://charts.konghq.com
  helm repo update
  helm upgrade --install kong-gw kong/kong -n gateway -f deployments/kong/values.yaml
```

Configurar rutas
```bash
  kubectl create configmap kong-config --from-file=kong.yaml=deployments/kong/kong-config.yaml -n gateway
  kubectl rollout restart deployment kong-gw-kong -n gateway
```

Probar Gateway
```bash
  kub ectl port-forward svc/kong-gw-kong-proxy -n gateway 8080:80
  curl http://localhost:8080/
```
