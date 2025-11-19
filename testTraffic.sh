#!/bin/bash

# Colores para output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

NAMESPACE="the-store"

echo "=========================================="
echo "  Testing Kuma Traffic Permissions"
echo "=========================================="
echo ""

# Función para probar conexión
test_connection() {
    local from=$1
    local to=$2
    local should_work=$3
    local service_url="http://${to}.${NAMESPACE}.svc.cluster.local"

    echo -n "Testing: ${from} → ${to} ... "

    # Ejecutar curl desde el pod origen
    result=$(kubectl exec -n ${NAMESPACE} deployment/${from} -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 ${service_url} 2>/dev/null)

    if [ "$should_work" = "ALLOW" ]; then
        if [ "$result" = "200" ] || [ "$result" = "404" ] || [ "$result" = "301" ] || [ "$result" = "302" ]; then
            echo -e "${GREEN}✓ PASSED${NC} (HTTP ${result}) - Conexión permitida como esperado"
        else
            echo -e "${RED}✗ FAILED${NC} (HTTP ${result}) - Debería estar permitida pero fue bloqueada"
        fi
    else
        if [ "$result" = "000" ] || [ "$result" = "" ] || [ "$result" = "503" ]; then
            echo -e "${GREEN}✓ BLOCKED ${NC} - Conexión bloqueada como esperado"
        else
            echo -e "${RED}✗ PASSED ${NC} (HTTP ${result}) - Debería estar bloqueada pero funcionó"
        fi
    fi
}

echo "=== CONEXIONES PERMITIDAS (deberían funcionar) ==="
echo ""
test_connection "ui" "catalog" "ALLOW"
test_connection "ui" "carts" "ALLOW"
test_connection "ui" "checkout" "ALLOW"
test_connection "ui" "orders" "ALLOW"
test_connection "checkout" "orders" "ALLOW"

echo ""
echo "=== CONEXIONES BLOQUEADAS (deberían fallar) ==="
echo ""
test_connection "catalog" "orders" "DENY"
test_connection "carts" "orders" "DENY"
test_connection "catalog" "checkout" "DENY"
test_connection "carts" "checkout" "DENY"
test_connection "orders" "catalog" "DENY"
test_connection "orders" "carts" "DENY"
test_connection "orders" "checkout" "DENY"
test_connection "checkout" "catalog" "DENY"
test_connection "checkout" "carts" "DENY"

echo ""
echo "=========================================="
echo "  Test Completo"
echo "=========================================="