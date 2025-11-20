#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

NAMESPACE="the-store"
SERVICE=${1:-ui}

echo "=========================================="
echo "  📡 Monitor de Access Logs en Vivo"
echo "=========================================="
echo ""

POD=$(kubectl get pod -n ${NAMESPACE} -l app.kubernetes.io/name=${SERVICE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD" ]; then
    echo -e "${RED}Error: No se encontró el pod del servicio '${SERVICE}'${NC}"
    echo ""
    echo "Servicios disponibles:"
    kubectl get pods -n ${NAMESPACE} -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/name}{"\n"}{end}' | sort -u
    exit 1
fi

echo -e "${CYAN}Servicio: ${SERVICE}${NC}"
echo -e "${CYAN}Pod: ${POD}${NC}"
echo ""
echo -e "${YELLOW}Leyenda de colores:${NC}"
echo -e "  ${GREEN}2xx - Éxito${NC}"
echo -e "  ${YELLOW}4xx - Error del cliente${NC}"
echo -e "  ${RED}5xx - Error del servidor${NC}"
echo ""
echo "Presiona Ctrl+C para salir"
echo "=========================================="
echo ""

# Seguir los logs en tiempo real con colores
kubectl logs -f -n ${NAMESPACE} ${POD} -c kuma-sidecar 2>/dev/null | while IFS= read -r line; do
    # Filtrar solo access logs
    if echo "$line" | grep -qE '\[.*\].*"(GET|POST|PUT|DELETE|PATCH)'; then
        # Colorear según código de respuesta
        if echo "$line" | grep -qE '\"2[0-9]{2}'; then
            echo -e "${GREEN}${line}${NC}"
        elif echo "$line" | grep -qE '\"4[0-9]{2}'; then
            echo -e "${YELLOW}${line}${NC}"
        elif echo "$line" | grep -qE '\"5[0-9]{2}'; then
            echo -e "${RED}${line}${NC}"
        else
            echo "$line"
        fi
    fi
done