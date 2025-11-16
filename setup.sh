#!/bin/bash
set -e

# Global configuration
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SERVICES="catalog cart checkout orders ui"

print_status() {
    local BLUE='\033[0;34m'
    echo -e "${BLUE}$1\033[0m"
}

print_success() {
    local GREEN='\033[0;32m'
    echo -e "${GREEN}$1\033[0m"
}

print_warning() {
    local YELLOW='\033[1;33m'
    echo -e "${YELLOW}$1\033[0m"
}

print_error() {
    local RED='\033[0;31m'
    echo -e "${RED}$1\033[0m"
}

check_prerequisites() {
    print_status "Checking prerequisites..."

    if ! docker info &> /dev/null; then
        print_error "Docker is not running. Please start Docker first."
        exit 1
    fi
    print_success "Docker is running"

    if ! command -v kind &> /dev/null; then
        print_error "Kind is not installed. Please install Kind first:"
        exit 1
    fi
    print_success "Kind is installed"

    if ! command -v kubectl &> /dev/null; then
        print_error "Kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    print_success "Kubectl is installed"

    if ! command -v kumactl &> /dev/null; then
        print_error "Kumactl is not installed. Please install kumactl first."
        exit 1
    fi
    print_success "Kumactl is installed"
}

create_cluster_and_deploy() {
    create_cluster
    [ "$SKIP_BUILD" = true ] && print_warning "Build skipped" || build_images
    load_images
    deploy_services
    deploy_mesh
    deploy_ingress
    setup_metrics
}

create_cluster() {
    print_status "Setting up Kind cluster..."

    if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        print_warning "Cluster '$CLUSTER_NAME' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Deleting existing cluster..."
            kind delete cluster --name $CLUSTER_NAME
            print_success "Cluster deleted"
        else
            print_status "Using existing cluster"
        fi
    fi

    if ! kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        print_status "Creating new Kind cluster '$CLUSTER_NAME'..."

        kind create cluster --name $CLUSTER_NAME --config dist/cluster.yaml


        print_success "Cluster created successfully"
    else
        print_success "Cluster '$CLUSTER_NAME' is ready"
    fi

    print_status "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    print_success "Cluster is ready"
}

build_images() {
    print_status "Building local Docker images..."
    print_status "Using image tag: $IMAGE_TAG"
    for service in $SERVICES; do
        print_status "Building $service service..."
        cd src/$service
        docker build -t the-store-$service:$IMAGE_TAG .
        cd ../..
    done
    print_success "All images built successfully"
}

load_images() {
    print_status "Loading images into Kind cluster..."
    for service in $SERVICES; do
        kind load docker-image the-store-$service:$IMAGE_TAG --name $CLUSTER_NAME
    done
    print_success "Images loaded into cluster"
}

deploy_services() {
    if kubectl get namespace $NAMESPACE &> /dev/null; then
        print_warning "Namespace '$NAMESPACE' already exists"
        read -p "Do you want to delete the namespace and all related resources? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Deleting namespace '$NAMESPACE' and all resources..."
            kubectl delete namespace $NAMESPACE
            print_status "Waiting for namespace deletion to complete..."
            kubectl wait --for=delete namespace/$NAMESPACE --timeout=300s
            print_success "Namespace '$NAMESPACE' deleted successfully"
        else
            print_status "Using existing namespace '$NAMESPACE'"
        fi
    fi

    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        print_status "Creating namespace '$NAMESPACE'..."

        kubectl apply -f dist/kuma/namespace.yaml

        print_success "Namespace '$NAMESPACE' is ready and configured for Kuma"
    fi

    print_status "Applying Kubernetes manifests to namespace '$NAMESPACE'..."
    kubectl apply -f $DIR/dist/kubernetes.yaml -n $NAMESPACE

    print_status "Waiting for all deployments to be available..."
    kubectl wait --namespace $NAMESPACE --for=condition=available deployments --timeout=300s --all
    print_success "All deployments are available"

    print_status "Waiting for all pods to be ready and running..."
    kubectl wait --namespace $NAMESPACE --for=condition=ready pods --timeout=300s --all
    print_success "All pods are ready and running"
}

deploy_mesh(){
    if ! kubectl get namespace kuma-system &> /dev/null; then
      print_status "Installing Kuma Service Mesh..."

      helm repo add kuma https://kumahq.github.io/charts
      helm repo update
      helm install --create-namespace --namespace kuma-system kuma kuma/kuma --version 2.12.4

      print_status "Waiting for Kuma Control Plane to be ready"
      kubectl wait --namespace kuma-system \
          --for=condition=ready pod \
          --selector=app=kuma-control-plane \
          --timeout=300s

      print_success "Kuma Service Mesh installed and ready"
    else
      print_success "Kuma already installed"
    fi

    print_status "Applying Mesh Configuration..."
    kubectl apply -f dist/kuma/mesh.yaml

    print_status "Applying Mesh Traffic Permissions..."
    kubectl apply -f dist/kuma/trafficPermission.yaml

    print_status "Restarting pods to trigger Kuma sidecar injection..."
    kubectl rollout restart deployment -n $NAMESPACE

    print_success "Mesh deployed"
}


deploy_ingress() {
    print_status "Installing Kong gateway..."
    helm install kong kong/ingress -n kong --create-namespace

    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

    kubectl apply -n kong -f dist/kong/gateway.yaml

    print_status "Enabling sidecar injection in Gateway"
    kubectl label namespace kong kuma.io/sidecar-injection=enabled

    kubectl rollout restart -n kong deployment kong-gateway kong-controller

    print_status "Adding HttpRoute to ingress"
    kubectl apply -f dist/kong/route.yaml

    print_status "Adding external traffic permissions"
    kubectl apply -f dist/kong/externalTrafficPermission.yaml

    print_success "Kong gateway successfully installed"
}

setup_metrics(){
    print_status "Setting up observability configuration"

    kumactl install observability | kubectl apply -f -

    kubectl apply -f dist/kuma/meshMetric.yaml
    kubectl apply -f dist/kuma/meshLog.yaml

    print_success "Observability successfully configured"
}


main() {
    IMAGE_TAG="latest"
    CLUSTER_NAME="the-store"
    NAMESPACE="the-store"
    SKIP_BUILD=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build) SKIP_BUILD=true; shift ;;
        esac
    done

    check_prerequisites
    create_cluster_and_deploy
}

main "$@"