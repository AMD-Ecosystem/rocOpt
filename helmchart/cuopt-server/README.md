# rocOpt Server Helm Chart

This Helm chart deploys the rocOpt Server with GPU support on Kubernetes.

## Prerequisites

- Kubernetes cluster with GPU nodes
- A GPU device plugin installed on the cluster
- Helm 3.x installed

<!-- TODO(rocopt-distribution): document the GPU device plugin / GPU operator combination supported by rocOpt deployments -->

## Selecting the Container Image

- To use a specific version of the rocOpt server, update the `image.tag` field in `values.yaml`.
- If the desired version is not available as a release, you may use a nightly image.

<!-- TODO(rocopt-distribution): link to the rocOpt container registry / available tags -->
## Installation

### 1. Add the chart repository (if publishing to a repository)
```bash
helm repo add cuopt-server https://your-repo-url
helm repo update
```

### 2. Install the chart
```bash
# Install with default values
helm install cuopt-server ./cuopt-server

# Install with custom values
helm install cuopt-server ./cuopt-server -f custom-values.yaml

# Install with inline overrides
helm install cuopt-server ./cuopt-server \
  --set resources.requests.nvidia.com/gpu=2 \
  --set resources.limits.nvidia.com/gpu=2
```

## Usage

### Port Forwarding (for ClusterIP service)
```bash
kubectl port-forward service/cuopt-server 5000:5000
```

### Accessing the Service
Once deployed, you can access the rocOpt server API at:
- `http://localhost:5000` (with port forwarding)
- Or through the service endpoint within the cluster

### Testing the Deployment
```bash
# Check pod status
kubectl get pods -l app.kubernetes.io/name=cuopt-server

# View logs
kubectl logs -l app.kubernetes.io/name=cuopt-server

# Check GPU allocation
kubectl describe pod -l app.kubernetes.io/name=cuopt-server
```

## Uninstall

```bash
helm uninstall cuopt-server
