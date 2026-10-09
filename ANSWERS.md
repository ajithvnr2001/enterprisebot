# Answers — Part 5

## Q1. Migrate ~40 Ingresses from ingress-nginx (EOL) to Gateway API with zero downtime

- **Inventory and classify first.** List all 40 Ingresses: hosts, paths, TLS secrets, annotations (`rewrite-target`, `canary`, `auth-*`, `rate-limit`, custom snippets). Those annotations are the main breakage risk — Gateway API has no 1:1 for `configuration-snippet` or Lua. Decide per-Ingress: native `HTTPRoute` (host/path/method/header match, request mirror, timeouts) vs keep a snippet via `NginxGatewayFabric` extension / `BackendTLSPolicy` / WAF sidecar.
- **Install Gateway API + a controller alongside, do not touch ingress-nginx.** Deploy Gateway API CRDs (pinned version) and e.g. Envoy Gateway / Istio / nginx-gateway-fabric in the same cluster. Create one `Gateway` (one LB IP) with `GatewayClass` + TLS (`TLSRoute`/`Gateway` listeners 80/443). Keep ingress-nginx running; you now have two data planes.
- **Mirror config, starting with lowest-risk hosts.** For each Ingress, generate `HTTPRoute` (same host, pathType, backend Service/port, filters: `RequestHeaderModifier`, `URLRewrite`, `RequestRedirect`). Convert TLS `Secret`s to `certificateRefs` on the Gateway listener (or `Secrets` per-route). Apply with `kubectl apply` + `helm diff`-style review; validate with `kubectl get httproute -o yaml` and `gateway api conformance` checks.
- **Shift traffic gradually with DNS/weight, not big-bang.** Point a canary DNS record (e.g. `canary.<host>`) at the new Gateway LB, `curl -H "Host: <host>"` both stacks and diff status/body/headers. Then move production DNS TTL down (300s → 60s), flip one host at a time, monitor 5xx, p99, TLS errors, and keep ingress-nginx as instant rollback (flip DNS back).
- **What breaks (expect it):**
  - Regex paths and `rewrite-target` (`/api(/|$)(.*)` → `/​$2`) need `URLRewrite` filters; subtle off-by-slash 404s.
  - Custom snippets, `auth-url`, `limit-rps`, `affinity: cookie` have no standard equivalent — need controller-specific policies or an auth sidecar; session-affinity loss causes logouts.
  - Default backend / catch-all, wildcard TLS (`*.example.com`), and `X-Forwarded-*` / `X-Real-IP` handling differ per implementation — log format and client-IP preservation must be re-tested.
  - Status/classic `kubectl describe ingress` tooling and dashboards stop working; update runbooks, alerts (`nginx_ingress_controller_requests` → gateway metrics), and ExternalDNS ownership (two controllers fighting for same DNS record).
- **Finish:** After 1–2 weeks green, scale ingress-nginx to 0, keep manifests for a week, then delete. Pin Gateway API + controller versions and add conformance tests to CI.
