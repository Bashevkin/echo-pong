# Architecture & Design Decisions

This document covers the technical approach, decisions, and cloud strategy for the ping-pong application.

---

## Deployment Strategy

The application is deployed to Kubernetes using a **RollingUpdate** strategy with `maxUnavailable: 0` and `maxSurge: 1`. This guarantees zero-downtime: a new pod must be ready before any old pod is terminated.

The app sleeps 10 seconds before binding to a port (by design). The readiness probe targets `/health` with `initialDelaySeconds: 15` so Kubernetes never routes traffic to a pod that hasn't finished starting up. The liveness probe starts at 20 seconds to avoid a race condition where a slow startup is mistaken for a hung process.

Traffic enters through an **nginx Ingress controller** — pods have no direct public exposure. The Service is `ClusterIP`-only.

---

## Scaling Strategy

**Horizontal Pod Autoscaler (HPA)** manages replica count between a minimum of 3 and maximum of 5, scaling on CPU utilization above 80%.

- **Minimum 3 replicas** — ensures high availability across node failures and during rolling updates (with `maxUnavailable: 0`, you need at least 2 healthy pods while 1 is being replaced).
- **CPU-based scaling** — appropriate for a stateless HTTP server; as request volume increases, CPU rises predictably.
- **On EKS** — the Cluster Autoscaler (or Karpenter) would add/remove EC2 nodes in response to unschedulable pods, extending the HPA scaling range as far as needed.

For higher traffic, thresholds or metric sources (e.g., request rate via KEDA + Prometheus) can be tuned without changing the application.

---

## Security Measures

### Container Security
- **Non-root:** The container runs as `uid/gid 65532` (the distroless `nonroot` user). The Kubernetes `securityContext` enforces this with `runAsNonRoot: true`, `runAsUser: 65532`, `allowPrivilegeEscalation: false`, and `readOnlyRootFilesystem: true`.
- **Minimal base image:** `gcr.io/distroless/static-debian12:nonroot` — no shell, no package manager, no OS utilities. The attack surface is the Go binary only.
- **Multi-stage build:** The builder stage uses the full Go toolchain; only the compiled static binary is copied into the final image.

### Secret Management
- The auth token is stored in a Kubernetes `Secret`, mounted as a file at `/etc/ping-pong/secret.txt`. The app reads `SECRET_FILE_PATH` at startup — the token never appears as an environment variable (avoids leaking it via `/proc`, logs, or `kubectl describe pod`).
- The `k8s/secret.yaml` in the repo contains a `REPLACE_ME` placeholder. The real secret is applied out-of-band before deploying.

### Vulnerability Scanning
- **Trivy** runs on every PR (results posted as a PR comment) and on every merge to `main` before a release is cut.
- Scans block on `CRITICAL` and `HIGH` severities with `--ignore-unfixed` — only actionable vulnerabilities block the pipeline.
- Results are uploaded to GitHub Security (SARIF) for tracking over time.
- Go upgraded to 1.26 specifically to resolve HIGH-severity stdlib CVEs identified during scanning.

### Network
- Pods are not directly reachable from outside the cluster. All traffic flows through the Ingress.

---

## CI/CD Pipeline

Two workflows handle the full lifecycle:

### `ci.yml` — Pull Request checks
Triggered on PRs to `main` that touch Go files, `go.mod`, or `Dockerfile`.

1. Builds a multi-arch image (`linux/amd64`, `linux/arm64`) tagged with `pr-<number>` and the short commit SHA, pushed to GHCR for testing.
2. Runs Trivy scan; posts the results as a PR comment.
3. Builds binaries in parallel for all four targets (`linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`) and uploads them as workflow artifacts (retained 7 days) for developer testing.

### `release.yml` — Merge to main
Triggered on pushes to `main` that touch code files.

1. **Build & Scan** — builds the multi-arch image tagged with the short SHA and runs Trivy. If vulnerabilities are found, the pipeline stops here and no release is cut.
2. **Semantic Release** — analyzes commit messages (Conventional Commits) to determine if a new version is warranted and what bump it requires (patch/minor/major). Creates a GitHub Release with auto-generated release notes.
3. **Promote Image** — if a new release was published, re-tags the already-scanned SHA image with the semantic version tag and `latest` using `docker buildx imagetools create` (no rebuild — the exact same image digest is promoted).
4. **Build & Upload Binaries** — builds release binaries for all four platforms and attaches them to the GitHub Release.

### PR Title Enforcement
A separate `pr-title.yml` workflow validates that PR titles follow Conventional Commits format (e.g., `feat:`, `fix:`, `ci:`) — this is what drives semantic versioning correctness.

---

## Multi-Architecture Builds

Both CI and release workflows use **Docker Buildx** with **QEMU emulation** to produce `linux/amd64` and `linux/arm64` images in a single build step, published as a multi-platform manifest to GHCR.

The Dockerfile uses `--platform=$BUILDPLATFORM` on the builder stage (runs native on the CI runner for speed) and `$TARGETOS`/`$TARGETARCH` for the final `go build` cross-compilation.

The Kubernetes Deployment uses `nodeAffinity` to **prefer** ARM64 nodes (`weight: 100`) while still allowing x86 fallback — suitable for mixed clusters or transitioning fleets.

---

## Versioning and Tagging Strategy

Versioning is driven by **Conventional Commits** + **semantic-release**:

| Commit prefix | Version bump |
|--------------|-------------|
| `fix:` | patch (1.0.x) |
| `feat:` | minor (1.x.0) |
| `feat!:` or `BREAKING CHANGE:` | major (x.0.0) |
| `ci:`, `docs:`, `chore:` | no release |

Every commit to `main` is first built and scanned. Only if Trivy passes does semantic-release run. Only if semantic-release determines a version bump is needed does an image get promoted and binaries get published.

GHCR tags produced per release:
- `ghcr.io/bashevkin/echo-pong:<short-sha>` — immutable, created at build time
- `ghcr.io/bashevkin/echo-pong:v1.2.3` — the promoted semantic version tag
- `ghcr.io/bashevkin/echo-pong:latest` — always points to the most recent release

### Managing Old and Stale Image Versions

**Retention policy options:**

1. **GitHub Container Registry lifecycle policies** — GHCR supports retention rules (in beta/GA depending on account type). Configure a policy to delete untagged/SHA-only images older than N days.

2. **GitHub Actions cleanup job** — a scheduled workflow using the `actions/delete-package-versions` action can prune:
   - All `pr-*` and SHA-only tags older than 30 days
   - All versioned tags except the last N releases

3. **On EKS with ECR** — Amazon ECR lifecycle policies are more mature:
   ```json
   {
     "rules": [
       {
         "rulePriority": 1,
         "description": "Keep last 10 tagged releases",
         "selection": {
           "tagStatus": "tagged",
           "tagPrefixList": ["v"],
           "countType": "imageCountMoreThan",
           "countNumber": 10
         },
         "action": { "type": "expire" }
       },
       {
         "rulePriority": 2,
         "description": "Remove untagged images after 7 days",
         "selection": {
           "tagStatus": "untagged",
           "countType": "sinceImagePushed",
           "countUnit": "days",
           "countNumber": 7
         },
         "action": { "type": "expire" }
       }
     ]
   }
   ```

---

## Cloud Deployment: EKS

### Architecture on AWS

```
Internet → Route53 → ALB (AWS Load Balancer Controller) → nginx Ingress → Service → Pods
```

In production, the EKS cluster and all supporting infrastructure (VPC, node groups, IAM roles, ALB controller, ECR repositories) are managed with **Terraform**. Application delivery is handled by **ArgoCD**, which watches the Git repository for changes to the `k8s/` manifests and reconciles the cluster state — no `kubectl apply` in CI/CD.

Key AWS components:
- **AWS Load Balancer Controller** — provisions ALBs from Ingress resources, replacing the Minikube tunnel
- **AWS Secrets Manager + Secrets Store CSI Driver** — secrets are mounted into pods as files from Secrets Manager, replacing the Kubernetes `Secret` object and enabling centralized rotation
- **IRSA (IAM Roles for Service Accounts)** — pods authenticate to ECR and Secrets Manager via IAM without static credentials
- **Karpenter** — node autoscaling in response to unschedulable pods, preferring Graviton (ARM64) instance types
- **ACM certificate** — TLS terminated at the ALB; pods communicate over plain HTTP inside the VPC

---

## Global Image Distribution

For teams pulling images across different AWS regions (Europe, APAC, US), the approach is **ECR Pull Through Cache (PTC)**.

Each regional ECR registry is configured with a pull-through cache rule pointing to GHCR (or another upstream). When a node in `eu-west-1` pulls `ghcr.io/bashevkin/echo-pong:v1.2.3` for the first time, ECR fetches and caches the image layers locally. Subsequent pulls in that region are served from ECR — no cross-ocean transfer, no dependency on GHCR availability.

```
Node (eu-west-1) → ECR PTC (eu-west-1) ──[cache miss]──→ GHCR
                                        ──[cache hit] ──→ local layers
```

**Why PTC over alternatives:**
- **No push changes needed in CI** — the release workflow continues pushing to GHCR. Regional caching is transparent.
- **No replication lag** — cache is populated on first pull in each region rather than pushed proactively to all regions upfront.
- **Lifecycle policies apply** — ECR lifecycle rules prune cached layers automatically, keeping storage costs bounded.
- **IAM-controlled access** — regional teams pull via their local ECR endpoint with IRSA; no GHCR tokens distributed to clusters.
