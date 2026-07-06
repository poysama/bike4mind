# Bike4Mind Helm chart

A Helm chart for running the open core of Bike4Mind on Kubernetes. It deploys
the same stack as [`compose.selfhost.yaml`](../../compose.selfhost.yaml) and the
[raw manifests in `deploy/k8s`](../k8s) . the app plus MongoDB, MinIO, ElasticMQ,
and Mailpit.

**Which should I use?** The [raw manifests](../k8s) are the simplest thing to
read and `kubectl apply`. This chart is the better fit if you already template
your deployments with Helm, want to override images/storage/ingress through
values, or want upgrades and rollbacks managed as releases. Both share the same
container images and the same `.env.selfhost`.

> **Single replica only.** The app runs at `app.replicaCount: 1` and is not safe
> to scale out yet (per-pod in-memory rate limits, in-process quest processing,
> no realtime websocket gateway). See the [deploy/k8s README](../k8s/README.md#single-replica-caveats)
> for the full explanation.

## Prerequisites

- A Kubernetes cluster, `kubectl`, and Helm 3.8+ (drilled with Helm 4).
- A default StorageClass that provisions `ReadWriteOnce` PVCs.
- Your `.env.selfhost` from the repo root (see [step 2 of the compose quickstart](../../SELF_HOST.md#2-configure-your-environment)).

The app image (`ghcr.io/bike4mind/bike4mind-selfhost`) is public and multi-arch,
so no build and no pull secret.

## Install

The chart reads all app config from a Secret built from `.env.selfhost`. Because
it holds real secrets, the chart does **not** create it . you create it once in
the release namespace, then install. Run from the repo root:

```bash
# 1. Namespace.
kubectl create namespace bike4mind

# 2. App config Secret from your .env.selfhost (the chart consumes it, and MinIO
#    reads MINIO_ROOT_USER / MINIO_ROOT_PASSWORD from the same Secret).
kubectl -n bike4mind create secret generic b4m-env --from-env-file=.env.selfhost

# 3. Install the chart. Do NOT pass --wait (see note below).
helm install b4m deploy/helm/bike4mind --namespace bike4mind
```

Watch it come up:

```bash
kubectl -n bike4mind get pods -w
```

> **Do not use `--wait`.** The `mongo-rs-init` and `minio-createbuckets` Jobs are
> post-install hooks, and the app's init container waits for the Mongo primary
> that `mongo-rs-init` creates. With `--wait`, Helm would block on the app
> becoming ready before running the hooks . a deadlock. A plain `helm install`
> is correct; the app goes ready on its own once the replica set is up (~1 min).

## Access and first run

Only the app is exposed. Port-forward it (and Mailpit to read the sign-in code):

```bash
kubectl -n bike4mind port-forward svc/app 3000:3000 &
kubectl -n bike4mind port-forward svc/mail 8025:8025 &
```

Open `http://localhost:3000`, request a sign-in code, read it from Mailpit at
`http://localhost:8025`, and finish signup . the first account becomes the admin.
The full flow (and the `/api/chat` example) is in the
[deploy/k8s README](../k8s/README.md#4-reach-the-app).

## Common overrides

| Value | Default | Purpose |
|-------|---------|---------|
| `envSecretName` | `b4m-env` | Name of the pre-created app-config Secret. |
| `app.image.tag` | `latest` | Pin the app to a specific published tag. |
| `mongo.storage` / `minio.storage` | `5Gi` | PVC sizes. |
| `mongo.storageClassName` / `minio.storageClassName` | `""` (cluster default) | Pin a StorageClass. |
| `app.ingress.enabled` | `false` | Expose the app via Ingress instead of port-forward. |
| `*.resources` | `{}` | Set CPU/memory requests and limits per component. |

Example . pin the image, size storage, and expose via ingress:

```bash
helm install b4m deploy/helm/bike4mind --namespace bike4mind \
  --set app.image.tag=sha-abc1234 \
  --set mongo.storage=20Gi --set minio.storage=50Gi \
  --set app.ingress.enabled=true --set app.ingress.host=bike4mind.example.com
```

## Note on service names

The backing Service names are fixed (`mongo`, `minio`, `sqs`, `mail`) so the
hostnames in `.env.selfhost` resolve unchanged . which means **one release per
namespace**. Install a second instance in its own namespace, not alongside the
first.

## Upgrade and uninstall

```bash
# Upgrade after editing values or bumping the image tag.
helm upgrade b4m deploy/helm/bike4mind --namespace bike4mind

# Uninstall (PVCs and the b4m-env Secret survive; delete the namespace for a full wipe).
helm uninstall b4m --namespace bike4mind
kubectl delete namespace bike4mind   # full wipe including data
```

## Security

Same hardening applies as the raw manifests . the backing services ship without
auth and are cluster-internal only. Before any shared or public-facing cluster,
enable Mongo auth, set strong MinIO credentials, point `MAIL_*` at a real SMTP
provider, and expose only the app (via Ingress + TLS). See the
[deploy/k8s README](../k8s/README.md#security).
