# The Store

[![Build](https://github.com/jupmoreno/the-store/actions/workflows/main.yml/badge.svg)](https://github.com/jupmoreno/the-store/actions/workflows/main.yml)

**The Store** is a modern e-commerce platform built with microservices architecture.

Our platform provides a complete shopping experience with:
- **Beautiful storefront** with customizable themes and responsive design
- **Scalable microservices** built with multiple languages and frameworks
- **Real-time inventory management** and order processing

## 🏗️ Architecture

The Store is built with a microservices architecture that uses different technologies:

![Architecture](/docs/images/architecture.png)

| Service | Language | Description |
|---------|----------|-------------|
| [UI](./src/ui/) | Java (Spring Boot) | Modern web interface with themes and chat bot |
| [Catalog](./src/catalog/) | Go | Product catalog API with search and filtering |
| [Cart](./src/cart/) | Java (Spring Boot) | Shopping cart management with Redis/DynamoDB |
| [Orders](./src/orders/) | Java (Spring Boot) | Order processing and management |
| [Checkout](./src/checkout/) | Node.js (NestJS) | Checkout orchestration and payment processing |


## 🛠️ Development

### Prerequisites
- [Docker](https://docs.docker.com/get-docker/) running
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) installed
- [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) installed

### Cluster Management

Use the `setup.sh` script to manage your local Kubernetes cluster:

```bash
# Create a new cluster and deploy all services
./setup.sh

# To skip docker build images
./setup.sh --skip-build
```

After running `./setup.sh`, access The Store at: **http://localhost**.

To access Kuma GUI:
```bash
kubectl port-forward svc/kuma-control-plane -n kuma-system 5681:5681
```

Access at **http://127.0.0.1:5681/**

