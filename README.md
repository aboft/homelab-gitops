# homelab-gitops

GitOps manifests for a k3s homelab cluster. Day-two operations are driven by [Argo CD](https://argo-cd.readthedocs.io/): a single root Application deploys everything under `platform/argocd/apps/`, which in turn deploys platform components and user-facing apps from this repo.

## Repository layout

```
bootstrap/                  # One-time cluster bootstrap (applied with kubectl)
  olm/                      # Operator Lifecycle Manager
  external-secrets-operator/  # ESO via OLM Subscription
  secret-access/            # ClusterSecretStore for 1Password
  argocd/                   # Argo CD namespace, secrets, and ingress (not the install itself)

platform/                   # Shared cluster infrastructure
  argocd/                   # Argo CD Helm values and app-of-apps definitions
  traefik/                  # Ingress controller values
  metallb/                  # Load balancer config
  cert-manager/             # TLS certificate operator and ClusterIssuer
  observability/            # Prometheus, Loki, Tempo, Alloy, extras
  aerospike-operator/       # Aerospike Kubernetes Operator (OLM Subscription)

apps/                       # Application workloads (Kustomize base + overlays)
  aboftybot/
  aerospike/
  jellyfin/
  nextcloud/
  ...
```

| Path | Purpose |
|------|---------|
| `bootstrap/` | Resources that must exist before Argo CD can take over (OLM, ESO, secret store, Argo CD prerequisites) |
| `platform/argocd/apps/` | Argo CD `Application` manifests — the app-of-apps entry point |
| `platform/` | Helm values and Kustomize config for platform services |
| `apps/<name>/base` | Shared manifests for an app |
| `apps/<name>/overlays/<env>` | Environment-specific overrides (namespace, secrets, image tags) |

## Prerequisites

- A running **k3s** cluster with `kubectl` configured
- **[1Password CLI](https://developer.1password.com/docs/cli/)** (`op`) authenticated, with a service account token stored at `op://k3s-homelab/onepassword-token/token`
- **Helm 3** (required for the one-time Argo CD install)
- **`local-path`** StorageClass (used by Aerospike PVCs)

## Cluster bootstrap

Bootstrap steps are applied manually with `kubectl`. After step 8, Argo CD owns ongoing reconciliation.

### 1. Install k3s

Install k3s on the control-plane node(s). This repo does not contain k3s install scripts.

### 2. Install OLM

```bash
kubectl apply -k bootstrap/olm
```

Wait for the OLM pods to become ready:

```bash
kubectl get pods -n olm
kubectl get pods -n operators
```

### 3. Install External Secrets Operator

ESO must be installed **before** the Argo CD bootstrap manifests, because those manifests create `ExternalSecret` resources.

```bash
kubectl apply -k bootstrap/external-secrets-operator
```

Verify the operator is running and CRDs are registered:

```bash
kubectl get csv -n external-secrets
kubectl get crd | grep external-secrets
```

> **Package name check:** the Subscription expects `external-secrets-operator` from `operatorhubio-catalog`. Confirm the name matches your cluster:
>
> ```bash
> kubectl get packagemanifests -n olm | grep -i external
> ```

### 4. Create the 1Password token secret

ESO uses this secret to authenticate against the 1Password SDK provider.

```bash
op read 'op://k3s-homelab/onepassword-token/token' | \
  kubectl create secret generic onepassword-token \
    -n external-secrets \
    --from-file=token=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
```

See `bootstrap/secret-access/onepassword-token.secret.example.yaml` for a non-CLI alternative.

### 5. Create the ClusterSecretStore

```bash
kubectl apply -k bootstrap/secret-access
```

Verify it becomes ready:

```bash
kubectl get clustersecretstore onepassword
```

The store points at the `k3s-homelab` vault and reads the token from the `onepassword-token` secret in `external-secrets`.

### 6. Bootstrap Argo CD prerequisites

This step creates the `argocd` namespace, `ExternalSecret` resources for the admin password and Redis auth, and the Argo CD ingress. It does **not** install Argo CD itself.

```bash
kubectl apply -k bootstrap/argocd
```

Wait for the secrets to sync before continuing:

```bash
kubectl get externalsecret -n argocd
kubectl get secret argocd-secret argocd-redis -n argocd
```

Argo CD Helm values (`platform/argocd/values.yaml`) expect these secrets to already exist (`createSecret: false`, `redis.existingSecret: argocd-redis`).

### 7. Install Argo CD (one-time)

Argo CD must be running before the root Application can be applied. Install it once with Helm using the values in this repo:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 9.5.19 \
  -f platform/argocd/values.yaml
```

Confirm the pods are up:

```bash
kubectl get pods -n argocd
```

After this, the `argocd` Application in the app-of-apps takes over ongoing management of the Helm release.

### 8. Bootstrap Argo CD apps

Apply the root Application, which points Argo CD at `platform/argocd/apps/`:

```bash
kubectl apply -f platform/argocd/root-apps.yaml
```

Argo CD will discover and sync all child Applications. From here, the cluster is GitOps-managed — changes pushed to `main` are reconciled automatically (prune + self-heal are enabled).

Check sync status:

```bash
kubectl get applications -n argocd
```

## Managed applications

The root Application (`homelab-root`) deploys everything listed in `platform/argocd/apps/kustomization.yaml`:

| Argo CD Application | Source | Namespace |
|---------------------|--------|-----------|
| `argocd` | Helm: `argo-cd` 9.5.19 | `argocd` |
| `traefik` | Helm: `traefik` 40.2.0 | `traefik` |
| `metallb` + `metallb-config` | Helm + Kustomize | `metallb-system` |
| `cert-manager` + `cert-manager-config` | Helm + Kustomize | `cert-manager` |
| `ako` | Kustomize: `platform/aerospike-operator` | `operators` |
| `aerospike-staging` | Kustomize: `apps/aerospike/overlays/staging` | `asdb-staging` |
| `aerospike-prod` | Kustomize: `apps/aerospike/overlays/prod` | `asdb-prod` |
| `aboftybot` | Kustomize: `apps/aboftybot/overlays/prod` | `aboftybot` |
| `aboftybot-dev` | Kustomize: `apps/aboftybot/overlays/dev` | `aboftybot-dev` |
| `jellyfin` | Kustomize: `apps/jellyfin/overlays/prod` | `jellyfin` |
| `nextcloud` | Kustomize: `apps/nextcloud/overlays/prod` | `nextcloud` |
| `observability-kps` | Helm: `kube-prometheus-stack` | `monitoring` |
| `observability-extras` | Kustomize: `platform/observability/externals` | `monitoring` |
| `observability-loki` | Helm: `loki` | `monitoring` |
| `observability-alloy` | Helm: `alloy` | `monitoring` |
| `observability-tempo` | Helm: `tempo` | `monitoring` |

Aerospike uses sync waves: the operator (`ako`, wave `0`) deploys before the clusters (wave `10`).

Some manifests under `apps/` (e.g. `wikijs/`) are not wired into Argo CD yet.

## Adding a new application

1. **Create the workload manifests** under `apps/<name>/`:
   - Put shared resources in `base/`
   - Put environment-specific config in `overlays/<env>/`
   - Use `secret.env.example` files as templates for gitignored secrets

2. **Create an Argo CD Application** in `platform/argocd/apps/<name>.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: my-app
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/aboft/homelab-gitops.git
       targetRevision: main
       path: apps/my-app/overlays/prod
     destination:
       server: https://kubernetes.default.svc
       namespace: my-app
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

3. **Register it** by adding the filename to `platform/argocd/apps/kustomization.yaml`.

4. **Commit and push** to `main`. Argo CD picks up the new Application on the next sync.

For Helm-based platform components, follow the multi-source pattern used by Traefik and observability apps (chart source + `$values/...` ref from this repo).

## Recreating the cluster

A full rebuild follows the bootstrap steps above in order:

1. k3s → OLM → ESO → 1Password token → ClusterSecretStore
2. Argo CD prerequisites → Helm install → root Application
3. Argo CD syncs all platform and app resources from Git

If Argo CD itself is already running and you only need to re-register apps (e.g. after accidental deletion of Application CRs):

```bash
kubectl apply -f platform/argocd/root-apps.yaml
```

Argo CD will recreate the child Applications and re-sync workloads from the repo.

To force a full re-sync of a single app:

```bash
argocd app sync <app-name>
# or via kubectl:
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

## Secrets

- **Bootstrap / platform secrets** (Argo CD admin password, Redis auth, Grafana admin) are pulled from 1Password via `ExternalSecret` + `ClusterSecretStore`.
- **App secrets** use per-app `ExternalSecret` resources and/or Kustomize `secretGenerator` with local `secret.env` files (gitignored). See each app's `secret.env.example` for required keys.
- The 1Password service account token is the only secret created manually during bootstrap (step 4).

## Migrating an existing cert-manager install

If cert-manager was installed ad hoc (e.g. via `helm install`), Argo CD can adopt the existing release once the Application syncs. Before the first sync:

1. Confirm your live `ClusterIssuer` matches `platform/cert-manager/config/clusterissuer.yaml` (especially the ACME email and HTTP-01 ingress class).
2. If you installed with a different Helm release name or chart version, either align the cluster to this repo or adjust `platform/argocd/apps/cert-manager.yaml` to match.

To avoid duplicate controllers, uninstall any manually-installed cert-manager only **after** verifying the Argo CD Application is healthy and the `letsencrypt` ClusterIssuer is ready.

## Notes

- **cert-manager** deploys before Traefik (sync wave `0`/`1`) so the `letsencrypt` ClusterIssuer exists when ingress TLS certificates are requested.
- **Traefik** is deployed by Argo CD, so the Argo CD ingress created in bootstrap will not get traffic until Traefik syncs. This is expected on first bootstrap.
- **MetalLB** must be up before Traefik's `LoadBalancer` IP (`192.168.88.10` in `platform/traefik/values.yaml`) is reachable.
- Aerospike-specific setup (enterprise feature keys, UDFs, local secrets) is documented in [`apps/aerospike/README.md`](apps/aerospike/README.md).
