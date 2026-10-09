# DevOps Take-Home — Enterprise Bot (demo service + Helm + debug lab)

## What this is

- `service/` (Part 1): tiny Python HTTP service (`GET /`, `GET /healthz`), env-driven `APP_NAME`/`VERSION`.
- `chart/` (Part 2): Helm chart (2 replicas, probes, ConfigMap, Service, Ingress `demo.local`).
- `setup.sh` (Part 3): one-command local setup (kind `demo` + ingress-nginx + image + chart).
- `lab/` (Part 4): fixed `broken-chart` + `FINDINGS.md` + recorded session.
- `ANSWERS.md` (Part 5): Gateway API migration answer.

## How to run and verify (Parts 1–3)

Prereqs (local, no cloud): `docker`, `kind`, `kubectl`, `helm`.

```bash
./setup.sh                 # creates/reuses kind cluster 'demo', installs ingress-nginx, builds+loads image, helm install demo/demo
./setup.sh                 # run twice — must exit 0 both times (idempotent gate)

# Verify pods + chart
kubectl -n demo get pods,svc,ingress
helm status demo -n demo

# Verify service directly (port-forward, bypasses Ingress)
kubectl -n demo port-forward svc/demo-demo 18080:80 &
curl -s http://localhost:18080/          # {"app":"demo","version":"0.1.0","pod":"..."}
curl -s http://localhost:18080/healthz   # {"status":"ok"}

# Verify ConfigMap drives APP_NAME/VERSION (harness changes them at runtime)
kubectl -n demo get cm demo-demo-config -o yaml
kubectl -n demo patch cm demo-demo-config --type merge -p '{"data":{"APP_NAME":"patched","VERSION":"9.9.9"}}'
kubectl -n demo rollout restart deploy/demo-demo && kubectl -n demo rollout status deploy/demo-demo
curl -s http://localhost:18080/          # {"app":"patched","version":"9.9.9",...}
# restore:
kubectl -n demo patch cm demo-demo-config --type merge -p '{"data":{"APP_NAME":"demo","VERSION":"0.1.0"}}'
kubectl -n demo rollout restart deploy/demo-demo

# Verify chart overrides (harness renders with --set)
helm template demo ./chart -n demo --set replicaCount=3 --set config.appName=foo | grep -E "replicas:|APP_NAME"
helm template demo ./chart -n demo --set ingress.host=custom.local | grep "host:"

# Verify via Ingress (host demo.local)
# Most reliable (no hostPort, works even with k3s on same VM): port-forward to controller
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 18081:80 &
curl -s -H 'Host: demo.local' http://127.0.0.1:18081/        # -> {"app":"demo",...}
curl -s -H 'Host: demo.local' http://127.0.0.1:18081/healthz # -> {"status":"ok"}
# Direct hostPort (needs kind extraPortMappings 80/443 from setup.sh):
# On clean machines (no k3s): curl -H 'Host: demo.local' http://127.0.0.1/
# On this VM (k3s klipper-lb also claims 127.0.0.1:80 via CNI-HOSTPORT, so 127.0.0.1 goes to k3s 404):
# use bridge IP which goes via DOCKER DNAT to kind (bypasses CNI-HOSTPORT for !127/8):
curl -s -H 'Host: demo.local' http://172.18.0.1/        # -> {"app":"demo",...} (kind node via bridge)
# Or node IP directly (no proxy):
curl -s -H 'Host: demo.local' http://172.18.0.3/        # -> {"app":"demo",...} (demo-control-plane)
# With /etc/hosts (clean machines):
# echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts
# curl -s http://demo.local/ && curl -s http://demo.local/healthz
```

Lab (Part 4):

```bash
cd lab
./scenario.sh up        # apply cluster-state + helm install broken-chart
./scenario.sh verify    # 11 checks; currently 9/11 PASS (reporter gap, see FINDINGS.md Defect 7)
```

## Resource requests/limits — why these numbers

`chart/values.yaml`:

```yaml
resources:
  requests: {cpu: 50m, memory: 64Mi}
  limits:   {cpu: 200m, memory: 128Mi}
```

- Follows the lab's `LimitRange` guardrails (`defaultRequest 50m/64Mi`, `default 200m/128Mi`,
  `max 1/512Mi`) so pods never get rejected (`maximum cpu ... is 1, but limit is 4` was Defect 4).
- `50m` (0.05 core) is enough for a stdlib Python server idling + handling a few rps;
  `200m` cap prevents a hot loop from starving the 2-CPU kind node (metrics with `2` CPUs
  made the node `Insufficient cpu`).
- `64Mi` req / `128Mi` lim fits the ~15MB Python RSS + headroom; `readOnlyRootFilesystem`
  + `emptyDir` not needed here (no disk cache like lab worker).
- Probes (`liveness /healthz 5s/10s`, `readiness /healthz 3s/5s`) use the same port as
  `containerPort` (8080 via `PORT` env) so kubelet never marks healthy pods unready.

Lab `broken-chart` uses the same `50m/64Mi → 200m/128Mi` (except fixed metrics) for the same reason.

## What I deliberately skipped, and the risk

- **No HorizontalPodAutoscaler / PDB / anti-affinity.** Risk: 2 replicas on one kind node still
  go down together on node failure; no autoscaling on CPU. Acceptable locally; production needs HPA + PDB + topology spread.
- **No TLS for Ingress (`demo.local` is http).** Risk: cleartext on loopback. Production needs cert-manager + `BackendTLSPolicy` / TLS `Secret`.
- **No image registry / digest pin.** `setup.sh` builds `demo-service:0.1.0` locally and `kind load`s it.
  Risk: tag is mutable, no provenance. Production should push to a registry with digest (`repo@sha256:...`) + Trivy scan (see bonus CI).
- **Single-node kind, no resource quotas.** Risk: noisy-neighbor; `LimitRange` helps but `ResourceQuota` per-ns is missing.
- **Lab reporter `/report` gap left open** (see `lab/FINDINGS.md` Defect 7). Risk: `verify` stays 9/11.
  I chose honest gap over fake fix (changing probe to `/` would hide the signal — automatic fail per brief).

## What I would change for production

- Registry + digest + signed images (cosign), Trivy `HIGH,CRITICAL` gate (bonus workflow included).
- `Ingress` → Gateway API (`Gateway` + `HTTPRoute`, `demo.local` → real DNS + TLS via cert-manager).
- HPA (CPU 70%), PDB (`minAvailable: 1`), `topologySpreadConstraints`, requests/limits tuned from load tests (not guesses).
- Observability: `/metrics` (Prometheus), structured JSON logs, `ServiceMonitor`, alerts on `5xx`/`p99`.
- Security: `seccomp RuntimeDefault` (already in chart `podSecurityContext`), `NetworkPolicy` (deny-all + allow ingress→svc, svc→dns, reporter→kube-apiserver only), `readOnlyRootFilesystem` (already), no `latest` tags, Dependabot + `helm lint` + `kubeconform` in CI.
- GitOps (Argo CD / Flux) instead of `helm upgrade --install` from laptop; separate `values-prod.yaml`.

## How I used AI

- Tools: OpenCode agent (Muse Spark 1.3, this session) for scaffolding + iteration; no Copilot/ChatGPT.
- Used for: initial `service/app.py` + `Dockerfile` draft, Helm chart skeleton (`deployment/configmap/service/ingress` + helpers), `setup.sh` idempotency pattern (`kind get clusters | grep -qx`, `kubectl create ns --dry-run | apply`, `helm upgrade --install`), and `FINDINGS.md` structure.
- Had to correct: agent first omitted `kubeadmConfigPatches: node-labels ingress-ready=true` in kind config (controller stayed `Pending` with `didn't match Pod's node affinity/selector`); fixed after `kubectl describe pod -l component=controller`. Agent also set `common.port: 8080` initially (copied comment) — corrected to `8081` after `docker logs ... listening on :8081` + `ExposedPorts 8081`. All `kubectl`/`docker`/`helm` outputs in `FINDINGS.md` and `part4-session.log` are from my cluster (re-ran every command, did not paste hallucinated output).
- Live defense: I can walk through every file, reproduce each defect (`./scenario.sh reset/up/verify`), and explain why `runAsUser: 65532` (not removing `runAsNonRoot`) and `emptyDir` (not `readOnlyRootFilesystem: false`) preserve least privilege.
