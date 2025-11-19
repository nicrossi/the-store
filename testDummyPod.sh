#!/bin/bash

echo "UI a catalog -> Permitido"
kubectl exec -n the-store deployment/ui -- curl -m 5 http://catalog/catalog/products


echo "Dummy a catalog -> Bloqueado"
kubectl exec -n the-store test-unauthorized -- curl -m 5 http://catalog/catalog/products

