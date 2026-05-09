# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a DevOps home assignment: take a Go ping-pong HTTP server to production with containerization, CI/CD, and Kubernetes deployment. The application code (`main.go`) is complete — the work is building the infrastructure around it.

## Application

Single Go file (`main.go`), no external dependencies (pure stdlib), Go 1.24.

**Run modes:**
- `server` (default): HTTP server on `$PORT` (default 8080), delays 10 seconds before accepting requests
- `cli`: CLI mode with `ping`/`pong` commands, requires `--password` flag

**Environment variables:**
- `SECRET_FILE_PATH` — path to a file containing the auth token (required at startup)
- `PORT` — server port (default: 8080)

**Endpoints:**
- `GET /ping` and `GET /pong` — require `Authorization: Bearer <token>` or `Authorization: <token>`
- `GET /health` — public, returns 200 OK when server is ready (use for K8s readiness probe)
- `GET /` — API docs HTML page

**Key behavior:** The server sleeps 10 seconds before binding. Kubernetes readiness probe must target `/health` with an initial delay of at least 10s or appropriate `failureThreshold`.

## Build & Run

```bash
# Build
go build -o ping-pong-app .

# Cross-compile
GOOS=linux GOARCH=amd64 go build -o ping-pong-app-linux-amd64 .
GOOS=linux GOARCH=arm64 go build -o ping-pong-app-linux-arm64 .

# Run server locally (requires secret file)
echo "mysecret" > /tmp/secret.txt
SECRET_FILE_PATH=/tmp/secret.txt go run main.go --mode=server

# Run CLI
SECRET_FILE_PATH=/tmp/secret.txt go run main.go --mode=cli --password=mysecret ping

# Test the server
curl -H "Authorization: Bearer mysecret" http://localhost:8080/ping
```

## Deliverables To Build

The `k8s/` and `.github/workflows/` directories exist but are empty (`.gitkeep` only). The following must be created:

1. **`Dockerfile`** — multi-stage, multi-arch, non-root user, minimal base (distroless/scratch)
2. **`.github/workflows/`** — CI/CD pipeline: build multi-arch images, security scan, push to GHCR (`ghcr.io`), create versioned releases (binaries + container)
3. **`k8s/`** — Deployment, Service, Ingress manifests; rolling update strategy; liveness + readiness probes

## Requirements Summary

- **Security:** No root in containers, pass Trivy/Grype scans (no critical/high CVEs in releases), no secrets in images
- **Multi-arch:** Both `linux/amd64` and `linux/arm64`; ARM64 preferred for K8s
- **K8s:** Zero-downtime rolling deployments, no direct internet (use Ingress), cluster pulls from GHCR
- **CI/CD:** Tag-triggered releases, both binary (GitHub Releases) and container (GHCR) artifacts
- **Versioning:** Semantic versioning tags; strategy for cleaning up old images
