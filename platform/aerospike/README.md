# Aerospike (homelab)

Kustomize manifests for running an [Aerospike](https://aerospike.com/) database cluster on Kubernetes. This is a GitOps-style layout: shared config lives in `base/`, and environment-specific tweaks live in `overlays/`.

The cluster is managed by the **Aerospike Kubernetes Operator** via an `AerospikeCluster` custom resource — not a plain Deployment.

This is mostly a playground for my home lab k3s cluster.

## Layout

```
base/                  # Shared cluster config (CR, UDFs, secrets)
overlays/staging/      # Namespace: asdb-staging
overlays/prod/         # Namespace: asdb-prod
```

Each overlay pulls in `base/` and sets its own namespace plus per-environment user passwords.

## Prerequisites

Before applying anything, you need:

1. **Aerospike Operator** installed in the cluster (provides the `AerospikeCluster` CRD).
2. **`local-path` StorageClass** — the cluster uses it for persistent volumes.
3. **Secrets filled in locally** (these files are gitignored):

   | File | Purpose |
   |------|---------|
   | `base/features.conf` | Enterprise feature key (required for the enterprise image) |
   | `base/secret.env` | Prometheus exporter credentials — copy from `base/secret.env.example` |
   | `overlays/<env>/secret.env` | User passwords for `auth-secret` — copy from `secret.env.example` |

## Quick reference

Run these from this directory (`data/aerospike/`).

**Preview what Kustomize will render** (no cluster changes):

```bash
kubectl kustomize overlays/staging
kubectl kustomize overlays/prod
```

**Dry-run apply** (sends manifests to the API server for validation, but does not persist):

```bash
kubectl apply -k overlays/staging --dry-run=server
```

Use `--dry-run=client` instead if you only want local validation without talking to the cluster.

**Apply for real:**

```bash
kubectl apply -k overlays/staging
# or
kubectl apply -k overlays/prod
```

**See what would change** before applying:

```bash
kubectl diff -k overlays/staging
```

## What's in the cluster

- **3-node** Aerospike Enterprise (`8.1.2.0`) with rack-aware storage
- **Namespace** `aboftybot` — device storage on `local-path` PVCs
- **Prometheus exporter** sidecar on port 9145
- **RBAC users** defined in the CR (`admin`, `colton`) with quota roles
- **Lua UDFs** mounted from a ConfigMap (`base/udfs.yaml`)

Apps connect via in-cluster DNS, e.g. `asdb.asdb-staging.svc.cluster.local:3000`.

## Notes for future me

- **Restart trick:** bump the `forceRollout` annotation in `base/deployment.yaml` to trigger a rolling restart without changing spec.
- **Node placement:** tolerations and `nodeSelector` for dedicated Aerospike nodes are commented out in the CR — uncomment when ready.
- **Secrets:** Kustomize `secretGenerator` builds secrets at apply time from local files. Don't commit `.env` or `features.conf`.
- **Prod vs staging:** same base config, different namespace and passwords. Staging is the safer place to try changes first.
