# NAS RAM usage

As of 2026-10-21 (15:30), measured on `nas` with `free`, `kubectl top`, `ps` and Prometheus (cAdvisor).

## Summary

The NAS uses 21.2 GiB of its 29.3 GiB RAM; 8.1 GiB is still available and swap is almost untouched (44 MiB of 16 GiB),
so there is no memory pressure yet, but the margin is shrinking.

- Pods (cgroup working set) account for 17.2 GiB. Five apps take 5.8 GiB of that: grampsweb 1.8 (web + celery),
  immich 1.2, dawarich 1.2, authentik 0.9, home assistant 0.8.
- Outside pods: k3s server 1.5 GiB, kernel slab 2.3 GiB (1.4 GiB of ext4 inode cache, mostly reclaimable), VS Code server 0.5 GiB.
- 77 of 86 running pods have no memory limit, so one runaway app can push the whole node into OOM.

## What consumes RAM

grampsweb is the biggest single app at 1.8 GiB, which is surprising for its use: it runs 8 gunicorn workers of ~190 MiB
each.

| Consumer | Where | MiB | Components |
| --- | --- | ---: | --- |
| kernel slab | host | 2359 | 1.4 GiB ext4 inode cache, mostly reclaimable |
| grampsweb | pod | 1830 | web 1367 (8 gunicorn workers) + celery 463 |
| k3s server | host | 1546 | apiserver, etcd, kubelet |
| media stack (11 pods) | pod | 1378 | jellyseerr, flaresolverr, slskd, *arr, qbittorrent |
| immich | pod | 1193 | server 840 + ML 215 + db 138 |
| dawarich | pod | 1184 | app 585 + sidekiq 312 + db 287 |
| authentik | pod | 961 | server 594 + worker 316 + ldap 51 |
| home assistant | pod | 777 | |
| nextcloud | pod | 698 | incl. built-in Collabora spares |
| grafana | pod | 675 | |
| open webui | pod | 610 | |
| music assistant | pod | 595 | |
| argocd | pod | 575 | 5 pods |
| prometheus | pod | 552 | 60 d retention, 91k series |
| firefox | pod | 536 | |
| ciq (mysql + wordpress) | pod | 533 | |
| VS Code server | host | 479 | |
| jellyfin | pod | 417 | |

Pods under 400 MiB are left out (about 2.7 GiB over 48 pods). Kernel slab is mostly ext4 inode and dentry cache that the
kernel frees under pressure, so it is not a real cost. Inside the nextcloud pod, Collabora (CODE) runs 4 idle pre-forked
`kit_spare` processes.

## What can be improved

The quickest wins are grampsweb's worker count and Collabora's spare processes in nextcloud: together about 1.5 GiB for
two small config changes. Savings are estimates from today's numbers.

| Action | Where | Est. saving | Effort |
| --- | --- | --- | --- |
| Run gunicorn with 2 workers instead of the default 8 (`GUNICORN_NUM_WORKERS=2`): each worker holds ~190 MiB for a family-tree app with one or two users | `apps/grampsweb` | ~1.1 GiB | env var |
| Built-in Collabora (CODE) in the nextcloud pod keeps 4 pre-forked `kit_spare` processes; lower `num_prespawn_children` to 1, or drop the app if Office editing is unused | `nextcloud` | ~0.3–0.6 GiB | occ / app setting |
| Cut grampsweb-celery concurrency to 1–2 workers | `apps/grampsweb` | ~0.2–0.3 GiB | env var |
| ✅ 2026-10-21 Scale idle apps to 0 and start them on demand: grampsweb, openwebui, firefox (Sablier, `SCALE-TO-ZERO-HTTP.md`). guacamole, meshcentral, flaresolverr were not chosen | `apps` | ~1.8 GiB while asleep | Sablier |
| Prometheus: drop the `apiserver_*` and `etcd_*` histogram buckets from the `kubelet` job (k3s exposes them on the same endpoint; they are the largest series of the 91k) with `metric_relabel_configs` | `monitoring/prometheus.yml` | ~0.1–0.2 GiB | relabel rule |
| Check why grafana uses 675 MiB (usually 100–200 MiB): plugins, image renderer, or a heavy dashboard left open | `monitoring/grafana.yaml` | ~0.4 GiB | investigate |
| dawarich sidekiq runs `BACKGROUND_PROCESSING_CONCURRENCY=10`; 3–5 is enough for one user | `dawarich/app.yaml` | ~0.1 GiB | env var |
| Three separate database servers: dawarich-db (287 MiB) and immich-database (138 MiB) next to `databases/postgres`. Kept apart because they need PostGIS / vectorchord; merging is possible but not worth the risk today | `dawarich`, `immich` | ~0.3 GiB | not recommended now |
| Close the VS Code remote server when not editing | host | ~0.5 GiB | habit |

Independently of the savings, add a memory **limit** to every pod (about 1.5–2× its current working set). Today only
9 pods have one, so a leak in any app is only stopped by the kernel OOM killer, which may pick postgres or k3s itself.
Requests are already set everywhere and sum to 17.0 GiB, close to real usage, so they can stay.

## Grafana: RAM per app

Nothing needs installing: Prometheus already scrapes the kubelet's cAdvisor (job `kubelet-cadvisor`) and node-exporter,
which is enough for a per-app breakdown. The metric to use is `container_memory_working_set_bytes`: it is what
`kubectl top` shows and what the OOM killer and limits act on (`container_memory_usage_bytes` also counts reclaimable
page cache and overstates). Filter `container!=""` to drop the pod-level cgroup totals, or every pod counts twice.

Suggested panels for a "RAM by app" dashboard:

1. **Stacked time series by namespace** (legend = `{{namespace}}`, unit bytes):

   ```promql
   sum by (namespace) (container_memory_working_set_bytes{container!="", container!="POD"})
   ```

2. **Top 15 pods, bar gauge** (instant query; the app name is the pod name minus its hash):

   ```promql
   topk(15, sum by (namespace, pod) (container_memory_working_set_bytes{container!="", container!="POD"}))
   ```

3. **"Not in pods"** = host used RAM minus all containers, which shows k3s, the kernel and host processes (VS Code) as
   one series to stack next to the namespaces:

   ```promql
   (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
     - scalar(sum(container_memory_working_set_bytes{container!="", container!="POD"}))
   ```

4. **Host overview** (stat panels): `node_memory_MemAvailable_bytes`, swap used
   `node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes`, and kernel slab `node_memory_SReclaimable_bytes` /
   `node_memory_SUnreclaim_bytes`.

5. **OOM kills and growth**: `increase(container_oom_events_total[1d]) > 0` as a table, and `max_over_time(...[7d])`
   of query 2 to spot apps that leak over a week.

Adding **kube-state-metrics** later would give `kube_pod_container_resource_requests` and `_limits`, to plot usage
against each pod's request/limit once limits are set; it is not needed for the breakdown itself. Add an alert on
`node_memory_MemAvailable_bytes < 3e9` (3 GB) to ntfy.
