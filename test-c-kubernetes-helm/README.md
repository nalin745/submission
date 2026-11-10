# auth-api – Kubernetes Manifests & Helm Chart

Production deployment of the **auth-api** microservice (authentication & authorization REST API) on **EKS 1.28**.

```
test-c-kubernetes-helm/
├── README.md
├── k8s/                         # plain manifests (kubectl apply -f k8s/)
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── configmap.yaml
│   ├── secret.yaml              # PLACEHOLDERS ONLY
│   ├── pdb.yaml
│   └── networkpolicy.yaml
└── helm/auth-api/               # parameterised chart
    ├── Chart.yaml
    ├── values.yaml              # defaults
    ├── values-dev.yaml
    ├── values-staging.yaml
    ├── values-prod.yaml
    ├── .helmignore
    └── templates/
        ├── deployment.yaml  service.yaml  ingress.yaml  hpa.yaml
        ├── configmap.yaml   secret.yaml   pdb.yaml      networkpolicy.yaml
        ├── _helpers.tpl
        └── NOTES.txt
```

## 1. Architecture overview

```
 Internet ──HTTPS──▶ AWS LB (NLB) ──▶ ingress-nginx (ns: ingress-nginx)
                                          │  TLS termination, HTTP→HTTPS redirect,
                                          │  rate limit 100 rps/IP, CORS (app.example.com)
                                          ▼
                                  Service auth-api (ClusterIP :80 → :3000)
                                          ▼
                      Deployment auth-api (3–20 pods, rolling update, PDB minAvailable 2)
                          │  ConfigMap → /app/config/config.json
                          │  Secret    → DATABASE_URL, REDIS_URL
                          ├──▶ RDS PostgreSQL     (5432, external, CIDR-restricted)
                          ├──▶ ElastiCache Redis  (6379, external, CIDR-restricted)
                          └──▶ kube-dns           (53 UDP/TCP)
```

| Concern | Implementation |
|---|---|
| Zero-downtime deploys | `RollingUpdate` maxSurge 1 / maxUnavailable 0, readiness probe, `preStop: sleep 10`, `terminationGracePeriodSeconds: 30` |
| Health | startup (`/health/startup`, initialDelay 10s), liveness (`/health/live`), readiness (`/health/ready`) on port 3000 |
| Resources | requests 250m/256Mi, limits 500m/512Mi |
| Scaling | HPA 3→20 on 70% CPU; scale-up window 60s, scale-down window 300s |
| Availability | PDB `minAvailable: 2`; zone topology spread |
| Network | NetworkPolicy: default-deny + ingress only from `ingress-nginx`; egress only DNS, RDS, ElastiCache |
| Secrets | Never in Helm values for staging/prod; `existingSecret` created out-of-band (kubectl / External Secrets) |
| Hardening | non-root, read-only root FS, drop ALL caps, seccomp RuntimeDefault, no SA token |

## 2. Prerequisites

- `kubectl` ≥ 1.28 and `helm` ≥ 3.12, with a kubeconfig for the cluster:
  `aws eks update-kubeconfig --region us-west-2 --name <cluster>`
- EKS 1.28 with:
  - **ingress-nginx** controller (namespace `ingress-nginx`, IngressClass `nginx`)
  - **cert-manager** + a `ClusterIssuer` (see *TLS* below)
  - **metrics-server** (required by the HPA)
  - A CNI that **enforces NetworkPolicy** (VPC CNI with network policy enabled, Calico, or Cilium) – otherwise policies are silently ignored
- Image pullable from ECR (`123456789012.dkr.ecr.us-west-2.amazonaws.com/auth-api:v1.2.3`); node IAM role needs `AmazonEC2ContainerRegistryReadOnly`
- Network reachability from the nodes/pods to RDS (5432) and ElastiCache (6379); update the CIDRs in the NetworkPolicy to your real subnets


## 3. Deploy with kubectl

```bash
kubectl create namespace auth-api

# Create the real secret out-of-band (do NOT apply k8s/secret.yaml with placeholders in production)
kubectl -n auth-api create secret generic auth-api-secrets \
  --from-literal=DATABASE_URL='postgresql://USER:PASS@<rds-endpoint>:5432/authdb' \
  --from-literal=REDIS_URL='redis://default:PASS@<elasticache-endpoint>:6379'

# Everything except secret.yaml
kubectl -n auth-api apply -f k8s/configmap.yaml -f k8s/service.yaml -f k8s/deployment.yaml \
  -f k8s/hpa.yaml -f k8s/pdb.yaml -f k8s/networkpolicy.yaml -f k8s/ingress.yaml

kubectl -n auth-api rollout status deploy/auth-api
```
(For a throw-away test you can `kubectl apply -f k8s/` – this includes the placeholder secret.)

## 4. Deploy with Helm

```bash
cd helm/auth-api
helm lint . -f values-prod.yaml
helm template auth-api . -f values-prod.yaml | kubectl apply --dry-run=server -f -   # optional validation

# DEV  (chart creates a placeholder secret; override via --set / CI)
helm upgrade --install auth-api . -n auth-api-dev --create-namespace -f values-dev.yaml \
  --set secret.databaseUrl='postgresql://...' --set secret.redisUrl='redis://...'

# STAGING (secret must pre-exist: auth-api-secrets)
helm upgrade --install auth-api . -n auth-api-staging --create-namespace -f values-staging.yaml

# PROD    (secret must pre-exist: auth-api-secrets)
helm upgrade --install auth-api . -n auth-api-prod --create-namespace -f values-prod.yaml \
  --set image.tag=v1.2.3 --atomic --timeout 5m
```
Create the secret in each namespace first (command in §3, with `-n <namespace>`).
`--atomic` automatically rolls back if the rollout does not become healthy.

Parameterised: `image.tag`, `replicaCount`, `resources.*`, `env.*` / `extraEnv`, `ingress.host`, `ingress.tls.*`, `ingress.clusterIssuer`, `autoscaling.*`, `pdb.*`, `networkPolicy.*`, `appConfig.*`.

## 5. Testing the deployment

```bash
kubectl -n auth-api get deploy,po,svc,ingress,hpa,pdb,networkpolicy
kubectl -n auth-api get certificate                   # READY=True

# Direct to the service
kubectl -n auth-api port-forward svc/auth-api 8080:80
curl -i localhost:8080/health/ready

# Through the ingress
curl -i http://auth-api.example.com/health/ready      # expect 308 → https
curl -i https://auth-api.example.com/health/ready     # expect 200

# CORS
curl -i -X OPTIONS https://auth-api.example.com/ \
  -H 'Origin: https://app.example.com' -H 'Access-Control-Request-Method: POST'
#  → Access-Control-Allow-Origin: https://app.example.com

# Rate limit (expect some 503 responses once over 100 rps per IP)
hey -z 10s -c 50 https://auth-api.example.com/health/ready     # or: ab / fortio

# HPA
kubectl -n auth-api get hpa auth-api -w
kubectl -n auth-api run load --rm -it --image=busybox -- sh -c 'while true; do wget -q -O- http://auth-api/health/ready; done'

# Zero-downtime rollout: run a curl loop in one terminal, then in another:
kubectl -n auth-api rollout restart deploy/auth-api

# PDB / drain behaviour
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # never goes below 2 ready pods

# NetworkPolicy: pods in other namespaces must be blocked
kubectl run -n default tmp --rm -it --image=busybox -- wget -T3 -qO- http://auth-api.auth-api.svc   # should time out
```

## 6. Rollback

```bash
# kubectl
kubectl -n auth-api rollout history deploy/auth-api
kubectl -n auth-api rollout undo deploy/auth-api                 # previous revision
kubectl -n auth-api rollout undo deploy/auth-api --to-revision=2

# Helm
helm history auth-api -n auth-api-prod
helm rollback auth-api <REVISION> -n auth-api-prod --wait
```
Config/secret changes: the ConfigMap/Secret checksum annotations roll pods automatically on `helm upgrade`; a `helm rollback` restores the previous config as well.

## 7. Troubleshooting

| Symptom | Checks / fix |
|---|---|
| `CreateContainerConfigError` | Secret `auth-api-secrets` missing or lacks `DATABASE_URL`/`REDIS_URL`: `kubectl -n auth-api get secret auth-api-secrets -o jsonpath='{.data}' \| jq 'keys'` |
| `ImagePullBackOff` | ECR auth/permissions, tag exists: `aws ecr describe-images --repository-name auth-api --region us-west-2` |
| Pods restart during start-up | Startup probe budget is 10s + 30×5s; raise `probes.startup.failureThreshold`; `kubectl logs --previous` |
| `OOMKilled` (`kubectl describe pod`) | Raise `resources.limits.memory`; check for leaks |
| Pods `Running` but not Ready | `kubectl describe pod` → readiness events; verify DB/Redis connectivity and NetworkPolicy CIDRs |
| DB/Redis timeouts | NetworkPolicy egress CIDRs must match your RDS/ElastiCache subnets; also check the security groups allow the **node/pod** SG on 5432/6379. Test: `kubectl -n auth-api exec deploy/auth-api -- nc -zv <endpoint> 5432` |
| DNS failures | Egress to kube-dns allowed? `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| 502/504 from ingress | `kubectl -n auth-api get endpoints auth-api` (empty = no ready pods); ingress-nginx logs; verify NetworkPolicy allows namespace `ingress-nginx` (label `kubernetes.io/metadata.name`) |
| Certificate not issued | `kubectl -n auth-api describe certificate,certificaterequest,order,challenge`; check ClusterIssuer exists and is Ready |
| HPA shows `<unknown>` | metrics-server not installed, or CPU `requests` missing |
| HPA flapping | Increase stabilization windows (`autoscaling.scaleDownStabilizationSeconds`) |
| Drain blocked | PDB `minAvailable: 2` with < 3 ready pods: scale up first, or fix unhealthy pods |
| Too many 503 on legit traffic | Raise `ingress.rateLimitRps` / `rateLimitBurstMultiplier` (clients behind one NAT share a limit) |
| CORS errors | `ingress.cors.allowOrigin` must exactly match the browser `Origin`; set `allowCredentials` appropriately |
| Helm upgrade stuck | `helm status`, `kubectl rollout status`; use `--atomic`; `helm rollback` |

## Design notes / assumptions
- **Secrets**: `k8s/secret.yaml` and chart defaults contain placeholders only. For prod use External Secrets Operator or Secrets Store CSI Driver with AWS Secrets Manager; the chart consumes any Secret via `secret.existingSecret`.
- **NetworkPolicy** is IP-based; it cannot reference AWS security groups. Restrict by subnet CIDR and use SGs on the AWS side as the second layer.
- **Read-only root FS** with `/tmp` as `emptyDir`; if the app writes elsewhere add another `emptyDir`.
- The app is assumed to read its JSON config from `APP_CONFIG_PATH` (`/app/config/config.json`); adjust the env var/mount path if the app expects another location.
- `k8s/` and the chart are kept in sync; the chart's defaults reproduce the manifests exactly.
