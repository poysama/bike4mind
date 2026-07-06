# Bike4Mind on Kubernetes

Run the open core of Bike4Mind on a Kubernetes cluster. These manifests are the same stack as [`compose.selfhost.yaml`](../../compose.selfhost.yaml) . the app plus MongoDB, MinIO object storage, an ElasticMQ queue, and a Mailpit mail catcher . expressed as Kubernetes objects.

**When to use which.** The [Docker Compose quickstart](../../SELF_HOST.md) is the fastest way to evaluate Bike4Mind on a single machine . one file, one command. Reach for these manifests when you want to run it on a cluster you already operate (k3s, kind, Docker Desktop, EKS/GKE/AKS) with Kubernetes' scheduling, restart, and config/secret handling. The two paths share the same container images and the same `.env.selfhost`, so nothing you configured for compose is wasted.

> **Single replica only.** The app runs at `replicas: 1` and is not safe to scale out yet: in-memory rate limits are per-pod, background quest processing runs in-process on the pod that accepts the request, and the realtime websocket gateway is not in this stack (live streaming updates degrade . chat replies appear on refresh). Horizontal scale waits on the websocket/fanout milestone. See [Single-replica caveats](#single-replica-caveats).

## What gets deployed

Everything lands in the `bike4mind` namespace. Service names match the compose service names exactly (`mongo`, `minio`, `sqs`, `mail`), so the queue URLs and endpoints in `.env.selfhost` resolve unchanged.

| Component | Kind | Notes |
|-----------|------|-------|
| `mongo` | StatefulSet + PVC + headless Service | Single-node replica set `rs0`. A one-shot `mongo-rs-init` Job runs `rs.initiate` (idempotent). |
| `minio` | StatefulSet + PVC + Service | S3-compatible storage. A one-shot `minio-createbuckets` Job creates the app's buckets. |
| `sqs` | Deployment + Service | ElasticMQ. Queues are predeclared from `elasticmq.conf` via a ConfigMap. |
| `mail` | Deployment + Service | Mailpit. Catches all outgoing mail, including sign-in codes. |
| `app` | Deployment (1 replica) + Service | The Bike4Mind app. An init container waits for the Mongo primary before starting. |

Only the `app` Service is meant to be exposed. Everything else is cluster-internal (`ClusterIP`).

## Prerequisites

- A Kubernetes cluster and `kubectl` pointed at it. Any of Docker Desktop's built-in Kubernetes, [kind](https://kind.sigs.k8s.io/), [k3s](https://k3s.io/), or a managed cloud cluster works. These manifests were drilled on kind.
- A default StorageClass that provisions `ReadWriteOnce` PVCs (all the common ones do . Docker Desktop, kind, EBS, etc.).
- ~4 GB of schedulable memory for the stack.
- The repo checked out locally (you need `.env.selfhost` and `elasticmq.conf` from the repo root).

You do **not** need to build anything. The app is pulled from `ghcr.io/bike4mind/bike4mind-selfhost:latest` (public, multi-arch amd64 + arm64), so no image build and no pull secret.

## 1. Prepare the environment file

The manifests read all app config from a Secret named `b4m-env`, built from the same `.env.selfhost` the compose stack uses. If you haven't made one yet, follow [step 2 of the compose quickstart](../../SELF_HOST.md#2-configure-your-environment): copy `.env.selfhost.example` to `.env.selfhost`, generate the three secrets, and set your LLM provider key(s).

Run the rest of these commands from the repo root, where `.env.selfhost` and `elasticmq.conf` live.

## 2. Create the namespace, Secret, and ConfigMap

The Secret and ConfigMap are created imperatively from the repo-root files so those files stay the single source of truth . no secrets committed to git, no duplicated queue config.

```bash
kubectl create namespace bike4mind

# App config (all env vars) -> Secret consumed by the app + MinIO + bucket job.
kubectl -n bike4mind create secret generic b4m-env --from-env-file=.env.selfhost

# Predeclared queues -> ConfigMap mounted into ElasticMQ at /opt/elasticmq.conf.
kubectl -n bike4mind create configmap elasticmq-config --from-file=elasticmq.conf
```

## 3. Apply the stack

```bash
kubectl apply -k deploy/k8s
```

Watch it come up. The backing services start first; the app's init container waits for the Mongo replica set to elect a primary, then the app starts.

```bash
kubectl -n bike4mind get pods -w
```

You want `mongo-0`, `minio-0`, `sqs`, `mail`, and `app` all `Running` (and `1/1` ready), with the `mongo-rs-init` and `minio-createbuckets` Jobs `Completed`.

## 4. Reach the app

Only the app is exposed. Port-forward it (and, optionally, Mailpit to read sign-in codes):

```bash
kubectl -n bike4mind port-forward svc/app 3000:3000 &
kubectl -n bike4mind port-forward svc/mail 8025:8025 &
```

Now follow the same first-run flow as compose:

1. Open `http://localhost:3000` . you should land on the login page with no errors.
2. Enter any email and request a sign-in code.
3. Open Mailpit at `http://localhost:8025` and read the 6-digit code.
4. Enter the code, pick a username, accept the policy checkboxes. The **first account becomes the admin** with no invite prompt.
5. Send a chat message (needs an LLM provider key set in `.env.selfhost`, or a local Ollama).
6. Optional API call: in **Settings > API Keys** create a key with the `ai:chat` scope, then:

   ```bash
   curl -X POST http://localhost:3000/api/chat \
     -H "x-api-key: $B4M_API_KEY" \
     -H "content-type: application/json" \
     -d '{"message": "Say hello in five words.", "wait": true}'
   ```

For real traffic, expose the `app` Service through an Ingress with TLS instead of port-forwarding.

## Security

These manifests, like the compose stack, ship the backing services **without authentication** . they are reachable only inside the cluster (`ClusterIP`). Before running Bike4Mind on a shared or public-facing cluster you **must**:

- Enable Mongo auth (a user + `--auth`) and use strong, non-default `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` in `.env.selfhost`.
- Point `MAIL_*` at a real SMTP provider (Mailpit is a local catcher, not a mail server).
- Put the app behind an Ingress with TLS, and keep every other Service cluster-internal (do not expose Mongo, MinIO, ElasticMQ, or Mailpit).
- Treat the `b4m-env` Secret as sensitive. Consider sealed-secrets or an external secret store instead of a plain Secret for anything beyond local eval.

## Single-replica caveats

The app is pinned to `replicas: 1` on purpose. Do not raise it yet:

- **Rate limits are per-pod.** They live in process memory, so N replicas would enforce N times the intended limit.
- **Quest / background processing runs in-process** on the pod that accepted the request. There is no shared work-queue dispatch across replicas, so a second replica would not pick up the first's in-flight work.
- **No realtime websocket gateway.** It is not part of this stack, so live streaming updates degrade to polling/refresh regardless of replica count.

Horizontal scale is a future milestone (the subscriber-fanout gateway lives outside the open-core repo).

## Notes on the Mongo file-descriptor limit

MongoDB/WiredTiger opens a file per collection and index and fatally panics with a "Too many open files" (EMFILE) error if the soft `nofile` limit is below its documented minimum of 64000. The compose stack raises this with a `ulimits` block. Kubernetes has **no** pod-level `nofile` setting . the limit is inherited from the container runtime. On the common runtimes (containerd, CRI-O) the default is already far above 64000 (often ~1 billion), so no action is needed, and this was confirmed on kind during the drill. If you hit a WiredTiger EMFILE panic on your platform, raise `LimitNOFILE` on the container runtime (for containerd under systemd, set `LimitNOFILE` in its unit and restart it).

## Teardown

```bash
# Remove the workloads (keeps the PVCs, so data survives a re-apply).
kubectl delete -k deploy/k8s

# Full wipe, including the Secret, ConfigMap, and persistent volumes.
kubectl delete namespace bike4mind
```
