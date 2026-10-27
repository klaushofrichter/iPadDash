# Cluster metrics for iPadDash — proposal

iPadDash (native iOS 12 app on an iPad Air 1) will replace its sample page with
cluster load and health. Latency of 5–10 minutes is fine. Data must refresh on a
tap, like the Steps & Claude page. Anything that needs attention is drawn in red.

## What the cluster already has (surveyed 2026-10-27)

- Single-node k3s cluster `skylar-technology`: node `klaus-optiplex-9020`
  (Ubuntu 24.04, k3s v1.36.5, up 453 days), 73 pods, 40 namespaces.
- metrics-server and kube-state-metrics are running.
- Grafana Cloud k8s-monitoring (Alloy, chart 4.4.0) ships metrics to
  `prometheus-prod-56-prod-us-east-2.grafana.net` and logs to Loki, labeled
  `cluster="skylar-technology"`.
- At survey time: CPU 24 %, memory 47 %, no node pressure, all pods Running,
  highest restart count 13 (kube-state-metrics), 7 warning events.

## Chosen path: iPad queries Grafana Cloud directly

```
cluster ──Alloy (already running)──▶ Grafana Cloud Prometheus ◀──query API (on tap / every N min)── iPad
```

- No new components: no CronJob, no steps-service endpoint, no cluster port
  exposed. The Cluster and Steps agents don't need to change anything.
- TLS works on iOS 12: the chain ends at DigiCert Global Root G2, TLS 1.2
  with ECDHE-RSA-AES128-GCM-SHA256 (checked).
- History is free: `query_range` gives the 24 h series for Grafana-style graphs.
- Auth: HTTP basic with the stack's Prometheus instance ID as user and a
  **read-only** Grafana Cloud access policy token (scope `metrics:read`) as
  password. The token Alloy uses is write-only and is not reused.

### Needed from the user

1. Grafana Cloud portal → Administration → Users and access → Cloud access
   policies → Create access policy, realm: this stack, scope: `metrics:read`
   only → Add token.
2. The Prometheus instance ID (stack details → Prometheus → "User").
3. Put both into `iPadDash/.env` (git-ignored):
   `GRAFANA_PROM_USER=<id>` and `GRAFANA_PROM_TOKEN=<token>`; deploy.sh bundles
   them like the steps token.

## What is actually available (checked with the token)

Alloy forwards only 29 metric names, so the `kube_*` series from
kube-state-metrics (node conditions, pod phases, restarts) are **not** in
Grafana Cloud. The page is built from what is there:

| Panel | PromQL (all with `cluster="skylar-technology"`) |
|---|---|
| CPU % (+24 h graph) | `100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))` |
| Memory % (+24 h graph) | `100 * (1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes))` |
| Disk % (root fs) | `100 * (1 - sum(node_filesystem_avail_bytes{mountpoint="/"}) / sum(node_filesystem_size_bytes{mountpoint="/"}))` |
| Load averages | `{__name__=~"node_load1|node_load5|node_load15"}` |
| Service up/down | `app_probe_success` (HTTPS probe per public service, from version-exporter) |
| Last backup | `time() - max(velero_backup_last_successful_timestamp)` |
| Certificates | `(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400` |
| CronJobs | `time() - cronjob_last_successful_timestamp_seconds` |
| Data freshness | `time() - max(timestamp(up))` |

Red thresholds live in `ClusterLimits` (ClusterService.swift): usage > 85 %,
backup or CronJob older than 26 h, certificate < 14 days, no samples for
30 minutes, any service probe failing.

For pod-level health (crash loops, restarts), the Cluster agent could add a few
kube-state-metrics series to Alloy's allow-list; the app would then add rows.

## Fallback

If a Grafana Cloud read token isn't wanted, the earlier relay still works: a
CronJob in the cluster POSTs a summary to a new steps-service `/cluster`
endpoint and the iPad reads it with its existing token. That needs the Cluster
and Steps agents and gives no history unless steps-service stores it.
