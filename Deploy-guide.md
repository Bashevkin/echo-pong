# Local Deployment Guide (Minikube)

## Prerequisites

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [gh](https://cli.github.com/) (optional, for image pull secret)

## 1. Start Minikube

```bash
minikube start
minikube addons enable ingress         # nginx ingress controller
minikube addons enable metrics-server  # required for HPA
```

## 2. Create the Secret

The `k8s/secret.yaml` contains a `REPLACE_ME` placeholder — do not apply it directly. Replace it before apply. 

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secret.yaml
```

## 3. Apply Manifests

```bash
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/ingress.yaml
```

## 4. Watch Pods Come Up

The app sleeps 10 seconds before binding — the readiness probe accounts for this.

```bash
kubectl get pods -n ping-pong -w
```

## 5. Access the App

### Option A — Via Ingress (recommended)

Run in a separate terminal and keep it alive:

```bash
minikube tunnel
```

Add to `/etc/hosts`:

```
127.0.0.1  ping-pong.local
```

Test:

```bash
curl -H "Authorization: Bearer <your-secret>" http://ping-pong.local/ping
curl -H "Authorization: Bearer <your-secret>" http://ping-pong.local/pong
curl http://ping-pong.local/health
```

### Option B — Port Forward (quick test)

```bash
kubectl port-forward svc/ping-pong 8080:80 -n ping-pong
curl -H "Authorization: Bearer <your-secret>" http://localhost:8080/ping
```

## Private GHCR Image

If the `ghcr.io/bashevkin/echo-pong` package is private, minikube cannot pull it without credentials. Create an image pull secret:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace ping-pong \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-pat>
```

Then add to `k8s/deployment.yaml` under `spec.template.spec`:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```
