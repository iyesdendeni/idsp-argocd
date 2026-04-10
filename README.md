# IDSP ArgoCD Deployment Reference

This repository contains the ArgoCD configuration to deploy the Symantec Identity Security Platform (IDSP) and its supporting services on Kubernetes using the **App of Apps** pattern.

---

## Table of Contents

1. [Repository Structure](#repository-structure)
2. [How It Works — App of Apps Pattern](#how-it-works--app-of-apps-pattern)
3. [Deployment Order — Sync Waves](#deployment-order--sync-waves)
4. [How to Deploy](#how-to-deploy)
5. [Services](#services)
   - [Ingress (nginx)](#1-ingress-nginx)
   - [MySQL](#2-mysql)
   - [Elastic Operator (ECK)](#3-elastic-operator-eck)
   - [Prometheus & Grafana](#3-prometheus--grafana)
   - [Elastic Stack (Elasticsearch + Kibana)](#4-elastic-stack-elasticsearch--kibana)
   - [SSP Infra](#5-ssp-infra)
   - [CA Directory](#3-ca-directory)
   - [SSP (IDSP)](#6-ssp-idsp)
   - [Sample App](#7-sample-app)
6. [Secrets Management — Sealed Secrets](#secrets-management--sealed-secrets)
7. [Data Retention Policy — Elasticsearch](#data-retention-policy--elasticsearch)
8. [Key Design Decisions](#key-design-decisions)
9. [Prerequisites & Manual Steps](#prerequisites--manual-steps)
10. [DNS Configuration](#dns-configuration)
11. [Deploying IDSP with ArgoCD](#deploying-idsp-with-argocd)

---

## Repository Structure

```
idsp-argocd-id604771/
├── idsp-parent-app.yaml          # The root ArgoCD Application (App of Apps)
├── apps/                         # Child ArgoCD Application manifests
│   ├── ingress.yaml              # ingress-nginx
│   ├── mysql.yaml                # MySQL with Sealed Secret
│   ├── kibana.yaml               # ECK Operator (Elastic Cloud on Kubernetes)
│   ├── elastic-stack.yaml        # Elasticsearch + Kibana instances
│   ├── grafana.yaml              # Prometheus + Grafana (kube-prometheus-stack)
│   ├── cadirectory.yaml          # CA Directory (Symantec Directory LDAP server)
│   ├── ssp-infra.yaml            # SSP Infrastructure chart
│   ├── ssp.yaml                  # SSP (IDSP) main chart
│   └── sample-app.yaml           # SSP Sample App (demo)
├── values/                       # Helm values files for each app
│   ├── ingress-values.yaml
│   ├── mysql-values.yaml
│   ├── kibana-values.yaml        # ECK operator values
│   ├── grafana-values.yaml       # kube-prometheus-stack values
│   ├── cadirectory-values.yaml   # CA Directory values
│   ├── ssp-infra-values.yaml
│   ├── ssp-values.yaml
│   └── sample-app-values.yaml
└── manifests/                    # Raw Kubernetes manifests applied by ArgoCD
    ├── mysql-sealed-secret.yaml  # SealedSecret for MySQL credentials
    ├── logging/                  # Logging stack manifests (applied by elastic-stack app)
    │   ├── elasticsearch.yaml
    │   ├── kibana.yaml
    │   ├── kibana-ingress.yaml
    │   ├── kibana-user-sealed-secret.yaml
    │   └── elasticsearch-retention-policy.yaml
    └── ssp/                      # SSP infra manifests (applied by ssp-infra app)
        └── fluent-bit-elastic-sealed-secret.yaml  # SealedSecret for fluent-bit → ES credentials
```

---

## How It Works — App of Apps Pattern

A single root Application (`idsp-parent-app.yaml`) is applied manually once to the cluster. It watches the `apps/` directory in this Git repository. ArgoCD discovers all child Application manifests in that directory and manages them automatically.

```
kubectl apply -f idsp-parent-app.yaml
        │
        ▼
ArgoCD watches apps/ directory
        │
        ├── ingress.yaml      → deploys ingress-nginx
        ├── mysql.yaml        → deploys MySQL
        ├── kibana.yaml       → deploys ECK operator
        ├── elastic-stack.yaml→ deploys Elasticsearch + Kibana
        ├── grafana.yaml      → deploys Prometheus + Grafana
        ├── ssp-infra.yaml    → deploys SSP Infrastructure
        ├── ssp.yaml          → deploys SSP (IDSP)
        └── sample-app.yaml   → deploys Sample App
```

Every time a file is pushed to the `main` branch of this repository, ArgoCD automatically syncs the changes to the cluster.

---

## Deployment Order — Sync Waves

ArgoCD sync waves control the order in which applications are deployed. Resources in lower wave numbers are deployed first and must be healthy before the next wave starts. Applications **in the same wave deploy in parallel**.

```
Wave 1:   ingress-nginx          (must be first — all other apps need nginx)
          │
Wave 2:   mysql                  (needs ingress)
          │
Wave 3:   elastic-operator  ─┐
          prometheus          ├── parallel (independent of each other)
          cadirectory        ─┘
                              │
Wave 4:   elastic-stack    ──┘  (needs ECK operator from wave 3)
          │
Wave 5:   ssp-infra             (needs mysql + ingress)
          │
Wave 6:   ssp                   (needs mysql + ssp-infra + ingress)
          │
Wave 7:   sample-app            (needs ssp to be running first)
```

> **Note:** Apps in the same wave (e.g. `elastic-operator` and `prometheus` both at wave 3) run in **parallel** — this is more efficient since they have no dependency on each other. The wave only advances when ALL apps at the current wave are healthy.

---

## How to Deploy

### First-time setup

1. Create all required namespaces manually:
   ```bash
   kubectl create namespace ingress
   kubectl create namespace logging
   kubectl create namespace monitoring
   kubectl create namespace ssp
   ```
2. Create TLS secrets and registry pull secret in each namespace (see [Prerequisites](#prerequisites--manual-steps))
3. Generate and commit all SealedSecrets (see [Secrets Management](#secrets-management--sealed-secrets)):
   - `manifests/mysql-sealed-secret.yaml`
   - `manifests/logging/kibana-user-sealed-secret.yaml`
   - `manifests/ssp/fluent-bit-elastic-sealed-secret.yaml`
4. Push all files to `https://github.gwd.broadcom.net/ESD/idsp-argocd-id604771.git`
5. Apply the parent app once:

```bash
kubectl apply -f idsp-parent-app.yaml
```

ArgoCD handles everything from that point forward.

### Subsequent changes

Push changes to the `main` branch. ArgoCD auto-syncs within minutes.

---

## Services

The IDSP platform is composed of eight services, each deployed as a separate ArgoCD Application and organised into distinct namespaces. The services are deployed in a strict order governed by sync waves: foundational infrastructure (ingress and database) comes first, followed by observability and logging components, and finally the IDSP application layer itself. Together, these services provide a complete identity security platform — from the network entry point and data persistence layer, through log collection and monitoring, to the application and its demo environment.

| Wave | Service                | Namespace     | Purpose                                       |
|:----:|------------------------|---------------|-----------------------------------------------|
|  1   | Ingress (nginx)        | `ingress`     | External traffic entry point for all services |
|  2   | MySQL                  | `ssp`         | Relational database for IDSP                  |
|  3   | Elastic Operator (ECK) | `logging`     | Manages Elasticsearch and Kibana lifecycle    |
|  3   | Prometheus & Grafana   | `monitoring`  | Metrics collection and dashboards             |
|  3   | CA Directory           | `ssp`         | LDAP directory server for IDSP identity store |
|  4   | Elastic Stack          | `logging`     | Elasticsearch cluster and Kibana UI           |
|  5   | SSP Infra              | `ssp`         | Fluent-bit log forwarding to Elasticsearch    |
|  6   | SSP (IDSP)             | `ssp`         | Main Identity Security Platform application   |
|  7   | Sample App             | `ssp`         | Demo application for testing IDSP             |

---

### 1. Ingress (nginx)

- **App file:** `apps/ingress.yaml`
- **Values:** `values/ingress-values.yaml`
- **Chart:** `ingress-nginx` from `https://kubernetes.github.io/ingress-nginx` v4.14.0
- **Namespace:** `ingress`
- **Sync wave:** 1

The ingress-nginx controller is the single entry point for all external HTTPS traffic into the cluster. It is deployed first (sync wave 1) because every other service that exposes a public endpoint — SSP, Kibana, Grafana, AlertManager, and the Sample App — depends on it to route traffic. The controller is assigned a static external IP address (`34.19.89.223`) via `loadBalancerIP`, ensuring that the DNS records for all services remain stable across restarts and redeployments. `externalTrafficPolicy: Local` is set to preserve the original client IP address in request headers, which is required by SSP for audit logging. Snippet annotations are enabled (`allowSnippetAnnotations: true`) to allow fine-grained nginx configuration on individual ingress resources, and a word blocklist is in place to prevent injection of unsafe directives.

---

### 2. MySQL

- **App file:** `apps/mysql.yaml`
- **Values:** `values/mysql-values.yaml`
- **Chart:** `mysql` from Bitnami v12.3.5
- **Namespace:** `ssp`
- **Sync wave:** 2

MySQL provides the relational database backend for IDSP, storing identity data, configuration, and audit records. It is deployed in replication mode with one primary and two read replicas, all using 50Gi `premium-rwo` persistent volumes to survive pod restarts. The primary is sized with 500m–2 CPU and 1–4Gi memory, with an InnoDB buffer pool of 1Gi and a maximum of 200 connections — sufficient for a production-grade IDSP workload. Credentials are never stored in plaintext; the chart reads them from the `mysql-credentials` Kubernetes Secret, which ArgoCD applies from `manifests/mysql-sealed-secret.yaml` and the Sealed Secrets controller decrypts at runtime. The database is named `iamauth` and uses `utf8mb4` character encoding as required by IDSP. `prune: false` is set deliberately on this ArgoCD Application to prevent ArgoCD from deleting the database PersistentVolumeClaims — and with them all data — if the MySQL manifest is ever temporarily removed from Git.

**Note on MySQL image:** `values/mysql-values.yaml` defaults to pulling the official `bitnami/mysql` image from `oci.bitnami.com`. If access to the Bitnami OCI registry is not available in your environment, uncomment the `bitnamilegacy` block in the values file to fall back to the `bitnamilegacy/mysql` image on Docker Hub. Note that `bitnamilegacy` images are frozen and no longer actively patched by Bitnami.
**Why `allowInsecureImages: true`?**
Starting with Bitnami chart v12.x, a security check validates that images come from the official Bitnami OCI registry. The `bitnamilegacy` namespace contains older frozen images that do not pass this check. If you need to use the `bitnamilegacy/mysql` from Docker Hub. If you need to use the bitnamilegacy images, then you need to set `allowInsecureImages: true` to bypass the check. The trade-off is that `bitnamilegacy` images are no longer actively patched by Bitnami.

---

### 3. Elastic Operator (ECK)

- **App file:** `apps/kibana.yaml`
- **Values:** `values/kibana-values.yaml`
- **Chart:** `eck-operator` from `https://helm.elastic.co` v3.2.0
- **Namespace:** `logging`
- **Sync wave:** 3

The Elastic Cloud on Kubernetes (ECK) operator is a Kubernetes operator from Elastic that manages the full lifecycle of Elasticsearch and Kibana clusters — provisioning, scaling, upgrades, TLS certificate rotation, and health monitoring — through Kubernetes custom resources. It must be deployed before the Elastic Stack application (wave 3 vs wave 4), because the Kubernetes API server does not know how to handle `Elasticsearch` and `Kibana` custom resource types until the operator's CRDs are registered. Its management scope is deliberately restricted to the `logging` namespace via `managedNamespaces: [logging]`, following the principle of least privilege — by default the operator would claim cluster-wide permissions to watch every namespace, which is unnecessary for this deployment. As part of its provisioning process, the operator automatically generates the secret `elasticsearch-es-elastic-user` in the `logging` namespace containing a randomly generated password for the built-in `elastic` superuser. This secret is never stored in Git; it is created entirely at runtime by the operator and can be retrieved at any time with:

```bash
kubectl get secret -n logging elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 --decode; echo
```

---

### 3. Prometheus & Grafana

- **App file:** `apps/grafana.yaml`
- **Values:** `values/grafana-values.yaml`
- **Chart:** `kube-prometheus-stack` from `https://prometheus-community.github.io/helm-charts` v78.5.0
- **Namespace:** `monitoring`
- **Sync wave:** 3
- **Helm release name:** `prometheus-operator`

The `kube-prometheus-stack` community chart deploys Prometheus, AlertManager, and Grafana together as a single, integrated monitoring stack. It runs in parallel with the ECK operator at wave 3, since the two are fully independent of each other. Prometheus is configured with a 1-minute scrape and evaluation interval, backed by a 20Gi `premium-rwo` persistent volume to retain metrics across restarts, and sized at 500m–2 CPU and 2–4Gi memory to handle a typical IDSP workload of 100–500 scrape targets. AlertManager is given its own 5Gi persistent volume for alert state. Grafana is exposed via nginx ingress at `grafana.id-broadcom.com` and provisioned at startup with the official SSP monitoring dashboard (Grafana.com ID `20026`), which provides pre-built panels for IDSP metrics — this requires outbound internet access from the cluster to `grafana.com` at deploy time. `ServerSideApply=true` is required because the chart's CRD manifests exceed the 1MB annotation limit imposed by standard client-side apply.

**Service URLs after deployment:**

| Service      | URL                                       | Credentials           |
|:-------------|:------------------------------------------|:----------------------|
| Grafana      | `https://grafana.id-broadcom.com`         | admin / prom-operator |
| AlertManager | `https://alertmanager.id-broadcom.com`    | —                     |

---

### 3. CA Directory

- **App file:** `apps/cadirectory.yaml`
- **Values:** `values/cadirectory-values.yaml`
- **Chart:** `ssp-symantec-dir` from `https://ssp-helm-charts-staging.storage.googleapis.com/ssp-maint-patch` v4.0.0-1153.stage
- **Namespace:** `ssp`
- **Sync wave:** 3
- **Helm release name:** `ssp-symantec-dir`

CA Directory is the Symantec LDAP directory server that provides the identity store for the IDSP platform. It is deployed at wave 3 in parallel with the ECK operator and Prometheus, since it has no dependency on any other application in this stack — it is a self-contained directory service. The chart is sourced from a separate Helm repository (`ssp-maint-patch`) distinct from the other SSP charts, as it follows an independent maintenance patch release cycle. The service is exposed as a `LoadBalancer` on port `389` (standard LDAP), making it reachable both within the cluster and from external clients that need to perform directory lookups. Images are pulled from the private staging registry using `ssp-registrypullsecret`.

---

### 4. Elastic Stack (Elasticsearch + Kibana)

- **App file:** `apps/elastic-stack.yaml`
- **Manifests:** `manifests/logging/`
- **Namespace:** `logging`
- **Sync wave:** 4

This application deploys the actual Elasticsearch cluster and Kibana instance using the ECK operator's custom resource types. It runs at wave 4, one wave after the ECK operator, because the operator must be fully running before Kubernetes can accept `Elasticsearch` and `Kibana` resources. Elasticsearch is deployed as a single-node cluster (version 9.2.1) combining master and data roles, with 1 CPU and 4Gi memory, backed by a 20Gi `premium-rwo` persistent volume. `node.store.allow_mmap: false` is set to avoid the need for elevated OS-level `vm.max_map_count` kernel tuning on the nodes. Authentication uses the file realm, referencing the `kibana-user` secret (decrypted from `kibana-user-sealed-secret.yaml`) to provision the `kibana` user with superuser role. Kibana (version 9.2.1) is connected to Elasticsearch via the ECK service reference, exposed as a `ClusterIP` service with a self-signed TLS certificate scoped to `kibana.id-broadcom.com`, and fronted by an nginx ingress. It is sized at 0.5–1 CPU and 1–2Gi memory.

**Components applied from `manifests/logging/`:**

| File                                  | What it creates                                              |
|---------------------------------------|--------------------------------------------------------------|
| `elasticsearch.yaml`                  | Single-node Elasticsearch cluster (non-HA, for non-production) |
| `kibana.yaml`                         | Kibana instance connected to Elasticsearch                   |
| `kibana-ingress.yaml`                 | nginx Ingress exposing Kibana at `kibana.id-broadcom.com`    |
| `kibana-user-sealed-secret.yaml`      | Kibana user credentials (SealedSecret)                       |
| `elasticsearch-retention-policy.yaml` | PostSync Job to configure ILM retention policies             |

**Kibana URL:** `https://kibana.id-broadcom.com`  
**Login:** username `kibana`, password as set in `kibana-user-sealed-secret.yaml`

#### Elasticsearch Data Retention (PostSync Hook)

The file `elasticsearch-retention-policy.yaml` is a Kubernetes **Job** annotated with `argocd.argoproj.io/hook: PostSync`. This means ArgoCD runs it **after all other resources in the elastic-stack app are healthy**.

The Job configures three ILM (Index Lifecycle Management) policies via the Elasticsearch REST API:

| Log Type      | Policy Name                   | Retention |
|:--------------|:------------------------------|:---------:|
| `ssp_audit*`  | `ssp_audit_lifecycle_policy`  |  30 days  |
| `ssp_log*`    | `ssp_log_lifecycle_policy`    |  10 days  |
| `ssp_tp_log*` | `ssp_tp_log_lifecycle_policy` |   7 days  |

For each log type it creates: an ILM policy → an index template → an initial writable index.

Rather than requiring an administrator to manually run `curl` commands against the Elasticsearch API after every deployment, the retention policy is fully automated as an ArgoCD PostSync hook. The Job waits in a readiness loop — polling the cluster health endpoint every 10 seconds — before making any API calls, ensuring it never fails due to Elasticsearch not yet being ready. For each log type it creates an ILM policy, an index template that binds the policy to matching indices, and an initial write index. Authentication uses the `ELASTIC_PASSWORD` environment variable injected from the `elasticsearch-es-elastic-user` secret auto-created by ECK, so no credentials are hardcoded. Once the Job completes successfully, ArgoCD deletes it automatically via `hook-delete-policy: HookSucceeded`, keeping the namespace clean.

---

### 5. SSP Infra

- **App file:** `apps/ssp-infra.yaml`
- **Values:** `values/ssp-infra-values.yaml`
- **Manifests:** `manifests/ssp/`
- **Chart:** `ssp-infra` from `https://ssp-helm-charts-staging.storage.googleapis.com` v4.0.0-1144.stage
- **Namespace:** `ssp`
- **Sync wave:** 5

SSP Infra is a Broadcom-provided Helm chart that deploys supporting infrastructure required by the IDSP platform, with its primary role in this deployment being log collection and forwarding via fluent-bit. It runs at wave 5, after MySQL and the logging stack are healthy, because fluent-bit must be able to reach Elasticsearch at startup to begin shipping logs. The chart is configured to disable its bundled database (`db.enabled: false`) since MySQL is managed separately. Fluent-bit collects the three SSP log streams — application logs, transaction processor logs, and audit logs — and forwards them over TLS to Elasticsearch in the `logging` namespace using cross-namespace cluster DNS (`elasticsearch-es-http.logging.svc:9200`). TLS verification is intentionally disabled (`tls.verify Off`) since Elasticsearch uses a self-signed certificate managed by ECK. The `sspReleaseName: ssp` value tells the chart to coordinate with the main SSP release for shared configuration.

#### Fluent-bit → Elasticsearch Log Forwarding

Fluent-bit is configured in `values/ssp-infra-values.yaml` to forward all three SSP log types to Elasticsearch:

| Tag | Index Pattern | Retention |
|---|---|---|
| `ssp_log` | `ssp_log-YYYY.MM.DD` | 10 days |
| `ssp_tp_log` | `ssp_tp_log-YYYY.MM.DD` | 7 days |
| `ssp_audit` | `ssp_audit-YYYY.MM.DD` | 30 days |

The Elasticsearch endpoint is `elasticsearch-es-http.logging.svc:9200` (cross-namespace DNS — fluent-bit in `ssp` namespace reaches Elasticsearch in `logging` namespace via cluster DNS).

#### Why `${ELASTIC_PASSWORD}` instead of a hardcoded password

The Broadcom documentation shows the following for the fluent-bit `HTTP_Passwd` field:

```
HTTP_Passwd $(kubectl get secret -n logging elasticsearch-es-elastic-user ...)
```

This is a **shell command substitution** that only works when generating a values file interactively from a shell. In a static YAML file committed to Git and read by ArgoCD, the `$(...)` expression is passed as a literal string to fluent-bit — it is never evaluated, and authentication would fail.

The GitOps-compatible solution uses fluent-bit's native **environment variable substitution**:

1. The password is stored in a SealedSecret (`manifests/ssp/fluent-bit-elastic-sealed-secret.yaml`) in the `ssp` namespace
2. The Sealed Secrets controller decrypts it into the `fluent-bit-elastic-credentials` Kubernetes Secret
3. The ssp-infra chart injects it as an environment variable `ELASTIC_PASSWORD` into the fluent-bit pod
4. Fluent-bit expands `${ELASTIC_PASSWORD}` at startup when reading its config file

#### Why use the `kibana` user instead of `elastic`

The `elastic` superuser password is **randomly generated** by the ECK operator at runtime and stored in a secret in the `logging` namespace. Fluent-bit runs in the `ssp` namespace and cannot directly reference secrets from a different namespace via `secretKeyRef`.

The `kibana` user is defined in `manifests/logging/kibana-user-sealed-secret.yaml` with a **known, fixed password** (`changeme`) that we control. This password can be sealed for the `ssp` namespace and referenced by fluent-bit. The `kibana` user has `superuser` role, which gives it write access to Elasticsearch indexes.

---

### 6. SSP (IDSP)

- **App file:** `apps/ssp.yaml`
- **Values:** `values/ssp-values.yaml`
- **Chart:** `ssp` from `https://ssp-helm-charts-staging.storage.googleapis.com` v4.0.0-1144.stage
- **Namespace:** `ssp`
- **Sync wave:** 6

SSP is the core Symantec Identity Security Platform application — the IDSP itself. It is deployed at wave 6, after all infrastructure components, because it depends on MySQL (wave 2), fluent-bit log forwarding (wave 5), and the ingress controller (wave 1) all being healthy and ready before it starts. It connects to MySQL at `mysql-primary.ssp.svc.cluster.local:3306`, using the `iamauth` database and user, with the password read from the `mysql-credentials` secret (the same secret created by the MySQL SealedSecret). The deployment is configured in **demo mode** (`ssp.deployment.size: demo`), which seeds the platform with a set of demo users, groups, and a demo client application at startup — making it immediately usable for testing and evaluation without any manual data setup. Two additional feature flags are enabled: `dataseed` (automatic data population) and `mcpserver` (MCP server support). A Hazelcast Enterprise in-memory data grid with 2 members is included for session clustering and caching. SSP is exposed via nginx ingress at `https://ssp.id-broadcom.com`, with TLS termination using the `ssp-general-tls` secret.

When SSP initialises in demo mode it automatically creates the Kubernetes secret `ssp-ssp-secret-democlient` in the `ssp` namespace, containing the `clientId` and `clientSecret` for the provisioned demo client application. This secret is consumed directly by the Sample App in the same namespace.

---

### 7. Sample App

- **App file:** `apps/sample-app.yaml`
- **Values:** `values/sample-app-values.yaml`
- **Chart:** `ssp-sample-app` from `https://ssp-helm-charts-staging.storage.googleapis.com` v4.0.0-1144.stage
- **Namespace:** `ssp`
- **Sync wave:** 7

The Sample App is a Broadcom-provided demo application that exercises the IDSP platform end-to-end, demonstrating login flows, token exchange, and API integration. It is deployed at wave 7 — after SSP (wave 6) — because it depends on SSP having completed its initialisation and created the `ssp-ssp-secret-democlient` secret containing the demo client credentials. By setting `sspReleaseName: ssp`, the chart automatically reads the `clientId` and `clientSecret` from that secret, and auto-detects the SSP service host from the SSP ingress — requiring no manual credential configuration. The Sample App is deployed in the same `ssp` namespace as SSP intentionally: Kubernetes `secretKeyRef` is namespace-scoped, so the chart cannot read `ssp-ssp-secret-democlient` from a different namespace without additional RBAC and a credential-copying Job. Deploying in the same namespace keeps the configuration simple, as the Broadcom documentation intends.

**Sample App URLs:**

| Component    | URL                                                    |
|:-------------|:-------------------------------------------------------|
| Web Sample App | `https://sampleapp-ssp.id-broadcom.com/sample-app`  |
| SPI Swagger  | `https://sampleapp-ssp.id-broadcom.com`                |
| Sample RP    | `https://sampleapp-ssp.id-broadcom.com/sample-rp/home` |

---

## Secrets Management — Sealed Secrets

Secrets are managed using [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets). Plain Kubernetes Secrets are **never** stored in Git. Instead, secrets are encrypted with `kubeseal` and stored as `SealedSecret` resources. The Sealed Secrets controller (running in `kube-system`) decrypts them at runtime.

### How to generate a SealedSecret

```bash
kubectl create secret generic <secret-name> \
  --from-literal=key1=value1 \
  --from-literal=key2=value2 \
  --dry-run=client -o yaml \
  -n <namespace> \
  | kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=kube-system \
      --format yaml > manifests/<path>/secret-name.yaml
```

### Existing SealedSecrets

| File | Secret Name | Namespace | Keys | Used By |
|---|---|---|---|---|
| `manifests/mysql-sealed-secret.yaml` | `mysql-credentials` | `ssp` | `mysql-root-password`, `mysql-password`, `mysql-replication-password` | MySQL chart, SSP chart |
| `manifests/logging/kibana-user-sealed-secret.yaml` | `kibana-user` | `logging` | `roles`, `username`, `password` | Elasticsearch fileRealm auth |
| `manifests/ssp/fluent-bit-elastic-sealed-secret.yaml` | `fluent-bit-elastic-credentials` | `ssp` | `password` | Fluent-bit → Elasticsearch auth |

### Regenerating MySQL credentials

```bash
kubectl create secret generic mysql-credentials \
  --from-literal=mysql-root-password=<password> \
  --from-literal=mysql-password=<password> \
  --from-literal=mysql-replication-password=<password> \
  --dry-run=client -o yaml \
  -n ssp \
  | kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=kube-system \
      --format yaml > manifests/mysql-sealed-secret.yaml
```

### Generating the fluent-bit Elasticsearch credentials

This SealedSecret stores the `kibana` user password for fluent-bit to authenticate to Elasticsearch. It must match the password set in `manifests/logging/kibana-user-sealed-secret.yaml`.

```bash
kubectl create secret generic fluent-bit-elastic-credentials \
  --from-literal=password=changeme \
  --dry-run=client -o yaml \
  -n ssp \
  | kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=kube-system \
      --format yaml > manifests/ssp/fluent-bit-elastic-sealed-secret.yaml
```

> **Important:** SealedSecrets are encrypted with the cluster's public key. A secret sealed on one cluster **cannot** be decrypted on a different cluster. If the cluster is rebuilt, secrets must be re-sealed.

---

## Data Retention Policy — Elasticsearch

Configured automatically by the PostSync Job in `manifests/logging/elasticsearch-retention-policy.yaml`. No manual steps required.

To manually verify the policies after deployment:

```bash
# Get the elastic password
ELASTIC_PASS=$(kubectl get secret -n logging elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 --decode)

# Check ILM policies
kubectl exec -n logging elasticsearch-es-default-0 -c elasticsearch -- \
  curl --insecure -u "elastic:${ELASTIC_PASS}" -s \
  "https://elasticsearch-es-http.logging.svc:9200/_ilm/policy" | python3 -m json.tool
```

---

## Key Design Decisions

The official Broadcom IDSP documentation is written for an interactive, shell-based installation — commands are run manually, passwords are retrieved with `kubectl` and substituted inline, and configuration is generated on the fly. Adapting this to a fully automated GitOps deployment introduced a number of non-trivial challenges: shell command substitutions that work interactively fail silently when committed as static YAML; secrets that are randomly generated at runtime cannot be pre-sealed and stored in Git; credentials needed by components in one namespace are inaccessible to pods running in another; and imperative post-deployment steps must be re-expressed as declarative, self-healing Kubernetes resources. Each of the decisions documented in this section represents a deliberate solution to one of these challenges, balancing GitOps correctness, security, and operational simplicity. Together they cover resource management, secrets handling, synchronisation ordering, and namespace scoping within the ArgoCD deployment workflow.

### Why is ArgoCD auto-applying `manifests/mysql-sealed-secret.yaml`?

The `mysql` ArgoCD Application has a third source pointing to `path: manifests` in this repo. ArgoCD watches that directory and applies all YAML files found there — including `mysql-sealed-secret.yaml`. No manual `kubectl apply` is needed. The Sealed Secrets controller then automatically decrypts the SealedSecret and creates the underlying `mysql-credentials` Secret.

### Why are MySQL and SSP in the same (`ssp`) namespace?

The SSP Helm chart uses `existingSecret: mysql-credentials` to find the MySQL credentials. Kubernetes secrets are namespace-scoped, so both MySQL and SSP must be in the same namespace for SSP to read that secret.

### Why does `mysql` have `prune: false`?

`prune: true` would cause ArgoCD to delete MySQL PersistentVolumeClaims if they are removed from Git, destroying all data. `prune: false` protects the database from accidental deletion.

### Why does the ECK operator use `managedNamespaces: [logging]`?

By default, the ECK operator manages Elasticsearch/Kibana resources across all namespaces, which requires broad cluster permissions. Restricting to `[logging]` follows the principle of least privilege.

### Why does the Elasticsearch `elasticsearch-es-elastic-user` secret not exist in Git? 

This secret is auto-generated by the ECK operator when it provisions the Elasticsearch cluster. It contains a randomly generated password for the built-in `elastic` superuser. Since the ECK operator creates it at runtime, it never needs to be manually created, sealed, or committed to Git.

### Why use two separate ArgoCD apps for ECK operator and Elasticsearch/Kibana?

The ECK operator must be running before any `Elasticsearch` or `Kibana` custom resources are applied — otherwise the Kubernetes API server doesn't know how to handle those resource types. Using two separate apps with sync waves (operator at wave 3, instances at wave 4) enforces this ordering reliably.

### Why does fluent-bit use a separate SealedSecret instead of the Kibana user secret directly?

The `kibana-user` SealedSecret is in the `logging` namespace (used by Elasticsearch). Fluent-bit runs in the `ssp` namespace. Kubernetes `secretKeyRef` only resolves secrets within the **same namespace** as the pod — there is no built-in cross-namespace secret reference in Kubernetes.

The solution is a separate SealedSecret (`fluent-bit-elastic-credentials`) sealed for the `ssp` namespace containing the same password. Both secrets reference the same `kibana` user credentials — they just exist in different namespaces for the components that need them.

### Why is the `manifests/ssp/` directory a separate source in `ssp-infra` rather than in `manifests/`?

The `manifests/` directory is watched by the `mysql` ArgoCD app (which applies everything in that directory to the `ssp` namespace). Adding unrelated secrets there would be semantically confusing. The `ssp-infra` app has its own dedicated third source pointing to `manifests/ssp/`, keeping concerns cleanly separated.

### Why is the Sample App deployed in the `ssp` namespace instead of its own namespace? 

The `ssp-sample-app` Helm chart reads the demo client credentials (`clientId` and `clientSecret`) from the secret `ssp-ssp-secret-democlient`, which SSP auto-creates in its own namespace at startup. Kubernetes `secretKeyRef` is namespace-scoped — a pod can only reference secrets in its own namespace. Deploying the Sample App in a separate namespace would require additional RBAC, a `PreSync` Job to copy the secret across namespaces, and cross-namespace configuration, adding significant complexity for no practical benefit in a demo environment.

### Why does fluent-bit use `${ELASTIC_PASSWORD}` instead of a shell command substitution?

The Broadcom documentation shows `HTTP_Passwd $(kubectl get secret ...)` as a shell command substitution. This only works when generating a values file interactively from a terminal — in a static YAML file committed to Git and read by ArgoCD, the `$(...)` expression is never evaluated and is passed as a literal string to fluent-bit, causing authentication to fail silently. The GitOps-compatible solution uses fluent-bit's native environment variable substitution: the password is stored in a SealedSecret, injected into the fluent-bit pod as `ELASTIC_PASSWORD`, and referenced in the config template as `${ELASTIC_PASSWORD}`.

### Why does fluent-bit authenticate as the `kibana` user instead of the `elastic` superuser?

The Broadcom documentation uses `HTTP_User elastic`, but the `elastic` password is **randomly generated** by the ECK operator at runtime — it is unknown before deployment and therefore cannot be pre-sealed and committed to Git. Using it would require a manual step after the first sync to retrieve the generated password, seal it for the `ssp` namespace, and push it back to Git, breaking full deployment automation. The alternative of overriding ECK's management of the built-in `elastic` user is fragile and unsupported. The `kibana` user is a purpose-created service account with a **known, fixed password** that we define in `manifests/logging/kibana-user-sealed-secret.yaml`. It can be sealed for both the `logging` namespace (where Elasticsearch reads it via file realm) and the `ssp` namespace (where fluent-bit reads it via `secretKeyRef`) before the first deployment, enabling a fully automated, single-command deployment. Both users have `superuser` role, so write access to Elasticsearch is equivalent.

### Why is `node.store.allow_mmap: false` set for Elasticsearch?

By default, Elasticsearch uses memory-mapped files (`mmap`) for Lucene index storage, which requires `vm.max_map_count=262144` to be set on every Kubernetes node at the OS level. Configuring this typically requires a `DaemonSet` or node pool initialisation scripts — cluster-level changes outside the scope of this GitOps repository. Setting `node.store.allow_mmap: false` switches Elasticsearch to standard file I/O, avoiding the OS dependency entirely. The trade-off is slightly lower read I/O performance for large index operations, which is acceptable for a non-production deployment.

### Why is the Elasticsearch ILM retention policy applied via a PostSync Job instead of manual commands?

The Broadcom documentation provides imperative `kubectl exec curl` commands to configure ILM policies after Elasticsearch is running. These are one-time manual steps that are incompatible with GitOps — they would need to be re-run manually after every cluster rebuild or redeployment. The PostSync Job in `manifests/logging/elasticsearch-retention-policy.yaml` encodes the same API calls declaratively, runs automatically after every successful sync of the `elastic-stack` application, and is cleaned up on success. This makes the retention policy self-healing and fully automated.

### Why does the Prometheus (grafana.yaml) application require `ServerSideApply=true`?

The `kube-prometheus-stack` chart ships very large CRD manifests. The IDSP documentations for the Prometheus deployment guide installs Prometheus using helm install directly. However, ArgoCD uses standard kubectl client-side apply which stores the full manifest in the `kubectl.kubernetes.io/last-applied-configuration` annotation, which has a hard limit of 1MB. The Prometheus CRDs exceed this limit, causing the apply to fail with an annotation size error. Server-side apply moves manifest tracking to the Kubernetes API server, bypassing the annotation size constraint entirely.

---

## Prerequisites & Manual Steps

All namespaces must be created manually **before** running `kubectl apply -f idsp-parent-app.yaml`. Although ArgoCD apps have `CreateNamespace=true` as a safety net, the TLS secrets and registry pull secret must exist in their respective namespaces before the first sync — and a secret cannot be created in a namespace that does not yet exist.

It is technically possible to automate namespace creation by adding a dedicated sync-wave "-1" ArgoCD Application that applies namespace manifests and SealedSecrets for TLS and registry credentials before all other apps sync. However, this introduces additional ArgoCD Application objects, extra Git structure, and tighter ordering constraints that add complexity for minimal benefit. Since namespace creation is a one-time bootstrap step consisting of four simple commands, creating them manually is the simpler and more transparent approach.

### Namespaces

Create all four application namespaces:

```bash
kubectl create namespace ingress
kubectl create namespace logging
kubectl create namespace monitoring
kubectl create namespace ssp
```

> `argocd` must also exist as a pre-installed namespace (ArgoCD itself runs there). See [How to Deploy](#how-to-deploy) for ArgoCD installation.

---

### TLS Secrets

| Secret Name | Namespace | Used By |
|---|---|---|
| `logging-general-tls` | `logging` | Kibana Ingress |
| `monitoring-general-tls` | `monitoring` | Grafana + AlertManager Ingress |
| `ssp-general-tls` | `ssp` | SSP Ingress |
| `sampleapp-general-tls` | `ssp` | Sample App Ingress (optional) |

Creation command:
```bash
kubectl create secret tls <secret-name> \
  --cert "${CERTFILE}" \
  --key "${KEYFILE}" \
  -n <namespace>
```

If a TLS secret is missing, the ingress-nginx controller falls back to its built-in self-signed certificate — the service still works but browsers will show a certificate warning.

### Registry Pull Secret

All SSP components use a private staging registry. The pull secret must exist in the `ssp` namespace:

```bash
kubectl create secret docker-registry ssp-registrypullsecret \
  -n ssp \
  --docker-server=<registry-server> \
  --docker-username=<username> \
  --docker-password=<password>
```

---

## DNS Configuration

All services are accessed via the domain `id-broadcom.com`. Add these entries to your cloud DNS or to `/etc/hosts` for local access.

Get the ingress IP:
```bash
kubectl get svc -n ingress ingress-nginx-controller
```

| Hostname | Service |
|---|---|
| `ssp.id-broadcom.com` | SSP (IDSP) |
| `sampleapp-ssp.id-broadcom.com` | Sample App |
| `kibana.id-broadcom.com` | Kibana |
| `grafana.id-broadcom.com` | Grafana |
| `alertmanager.id-broadcom.com` | AlertManager |

---

## Deploying IDSP with ArgoCD

Once all prerequisites are in place (namespaces created, secrets and SealedSecrets generated, DNS configured), the deployment follows a straightforward three-step process: publish the configuration to Git, trigger ArgoCD with a single command, and validate that all services are running correctly.

---

### Publishing the Configuration to Git

Before ArgoCD can deploy anything, the full repository content — including all ArgoCD Application manifests, Helm values files, raw Kubernetes manifests, and the three SealedSecret files — must be committed and pushed to the `main` branch of the Git repository. ArgoCD polls this branch continuously and will not act on changes that have not been pushed.

```bash
# Stage all new and modified files
git add .

# Commit with a descriptive message
git commit -m "Initial IDSP ArgoCD deployment configuration"

# Push to the main branch
git push origin main
```

> If you are updating an existing deployment (e.g. changing a Helm value or regenerating a SealedSecret), the same `git add / commit / push` flow applies. ArgoCD will detect the change on the next poll cycle (typically within 3 minutes) and automatically reconcile the cluster to match the new desired state.

---

### Running the Deployment

With the configuration published to Git, apply the root ArgoCD Application once. This single command hands full control of the IDSP deployment to ArgoCD:

```bash
kubectl apply -f idsp-parent-app.yaml
```

ArgoCD will discover the parent application, read the `apps/` directory from the Git repository, and create all eight child applications. Each application will then sync according to its assigned wave, deploying the full IDSP platform in the correct order with no further manual intervention required.

To monitor the sync progress from the command line:

```bash
# Watch all ArgoCD applications and their sync/health status
kubectl get applications -n argocd -w
```

---

### Validating the Deployment

Once all applications report `Synced` and `Healthy` in ArgoCD, proceed through the following validation steps to confirm the platform is fully operational.

---

#### ArgoCD Admin UI Validation

Open the ArgoCD UI and verify that all eight applications are in `Synced` / `Healthy` state. For each application, drill into the resource tree to inspect the individual Kubernetes objects ArgoCD has deployed.

**Expected application list in the ArgoCD UI:**

| Application      | Expected Status | Expected Health |
|:-----------------|:---------------:|:---------------:|
| ingress          | Synced          | Healthy         |
| mysql            | Synced          | Healthy         |
| elastic-operator | Synced          | Healthy         |
| prometheus       | Synced          | Healthy         |
| elastic-stack    | Synced          | Healthy         |
| ssp-infra        | Synced          | Healthy         |
| ssp              | Synced          | Healthy         |
| sample-app       | Synced          | Healthy         |

For each application, the resource tree in the UI should show:
- **Deployments / StatefulSets** — green (all replicas available)
- **Pods** — green (Running)
- **Services** — green
- **Ingresses** — green (address populated with the load balancer IP)
- **PersistentVolumeClaims** — green (Bound) for MySQL, Elasticsearch, Prometheus, and AlertManager
- **PostSync Jobs** (elastic-stack) — Completed and cleaned up

> **Screenshot guidance:** Capture the main Applications grid showing all eight apps in green, then capture the resource tree for each individual application, focusing on Pods, Services, and Ingresses.

---

#### kubectl Command Validation

Verify the running state of each namespace from the command line.

**`ingress` namespace — ingress-nginx controller:**
```bash
kubectl get pods,svc -n ingress
```

**`logging` namespace — Elasticsearch, Kibana, ECK operator:**
```bash
kubectl get pods,svc -n logging
```
Expected pods: `elasticsearch-es-default-0`, `kibana-kb-*`, `elastic-operator-*`

**`monitoring` namespace — Prometheus, AlertManager, Grafana:**
```bash
kubectl get pods,svc -n monitoring
```
Expected pods: `prometheus-operator-prometheus-*`, `prometheus-operator-alertmanager-*`, `prometheus-operator-grafana-*`

**`ssp` namespace — MySQL, SSP Infra, SSP, Sample App:**
```bash
kubectl get pods,svc -n ssp
```
Expected pods: `mysql-primary-0`, `mysql-secondary-*`, fluent-bit DaemonSet pods, SSP pods, Sample App pods

**Check PersistentVolumeClaims are all Bound:**
```bash
kubectl get pvc -n ssp
kubectl get pvc -n logging
kubectl get pvc -n monitoring
```

**Check all Ingresses have an IP address assigned:**
```bash
kubectl get ingress -A
```
All ingress resources should show the static load balancer IP `34.19.89.223` in the `ADDRESS` column.

---

#### Service URL Validation

With DNS configured (see [DNS Configuration](#dns-configuration)), access each service in a browser to confirm end-to-end connectivity.

| Service     | URL                                                       | Expected Result                                 |
|:------------|:----------------------------------------------------------|:------------------------------------------------|
| SSP (IDSP)  | `https://ssp.id-broadcom.com`                             | IDSP login page loads                           |
| Sample App  | `https://sampleapp-ssp.id-broadcom.com/sample-app`        | Sample App home page loads                      |
| SPI Swagger | `https://sampleapp-ssp.id-broadcom.com`                   | Swagger UI for the SPI API loads                |
| Sample RP   | `https://sampleapp-ssp.id-broadcom.com/sample-rp/home`    | Sample Relying Party home page loads            |
| Kibana      | `https://kibana.id-broadcom.com`                          | Kibana login page — log in as `kibana` user     |
| Grafana     | `https://grafana.id-broadcom.com`                         | Grafana login page — log in as `admin` / `prom-operator` |
| AlertManager| `https://alertmanager.id-broadcom.com`                    | AlertManager status page loads                  |

**Validate SSP log ingestion in Kibana:**

1. Log in to Kibana at `https://kibana.id-broadcom.com`
2. Navigate to **Discover**
3. Confirm that indices `ssp_log-*`, `ssp_tp_log-*`, and `ssp_audit-*` are present and receiving documents

**Validate SSP metrics in Grafana:**

1. Log in to Grafana at `https://grafana.id-broadcom.com`
2. Navigate to **Dashboards → Default**
3. Open the **SSP Monitoring** dashboard (auto-provisioned from Grafana.com ID `20026`)
4. Confirm panels are populated with live Prometheus metrics
