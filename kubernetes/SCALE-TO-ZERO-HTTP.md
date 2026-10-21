# Web apps: scale to zero when unused (Sablier)

Written 2026-10-21. Status: **applied 2026-10-21**. Same idea as Minecraft (`games/SCALE-TO-ZERO.md`), for HTTP apps behind Traefik.

## Decisions (asked 2026-10-21)

- Apps: **grampsweb (+ grampsweb-celery), openwebui, firefox**. Picked from RAM-USAGE.md: large working set, a few requests a day.
  **guacamole (+ guacd)** added 2026-10-21. Not chosen: the small apps (lubelogger, trilium, warracker, actual, adminer, speedtest), jellyseerr/musiseerr,
  meshcentral (its agents hold a connection open). flaresolverr is called by prowlarr directly, not through Traefik: Sablier can't wake it.
- Idle delay: **30 min** without a request (`sessionDuration`).
- Wake-up: **waiting page** (`dynamic` strategy, theme `ghost`, reloads every 5 s until the app is Ready). The `blocking` strategy
  isn't supported on Kubernetes by the plugin anyway.
- Plugin: **vendored** in git (`cluster/base/sablier-plugin/`, v1.3.1, ~500 lines of Go, stdlib only, reviewed: its only network calls
  go to `sablierUrl`), mounted into Traefik as a local plugin from ConfigMap `kube-system/traefik-plugin-sablier`. Traefik never
  downloads it, so a reboot without DNS still works.

Saving: ~2 GiB while all sleep (grampsweb ~700 MiB, openwebui ~600 MiB, firefox ~535 MiB, guacamole ~250 MiB) for ~20 MiB of Sablier.

## How it works

```
browser ──► Traefik ──► Middleware <app>-sablier (plugin) ──► GET sablier.infra:10000/api/strategies/dynamic?group=<app>
                              │                                   │ starts the group's Deployments (replicas 0 → 1), renews the session
                              │ ready? → request goes on to the Service, else → waiting page
                              ▼
                         Service <app>
```

- **Sablier** (`infra/sablier.yaml`): Kubernetes provider, ClusterRole on `deployments`/`statefulsets` (+ `/scale`). It handles every
  workload labelled `sablier.enable: "true"`; `sablier.group` ties it to a Middleware. A group's Deployments start and stop together
  (grampsweb + celery). An instance is Ready when `readyReplicas == replicas`, so the readinessProbe gates the waiting page.
- **Middleware** per app, next to its IngressRoute (`apps/<app>/<app>.yaml`). firefox: after `authentik` (an anonymous hit doesn't wake it),
  plus `keepAliveInterval: 5m` so an open VNC websocket keeps the session alive. guacamole: same keep-alive (remote session websocket),
  but no forward-auth (it logs in with its own OIDC), so any hit on its hostname wakes it. openwebui and gramps have no keep-alive: a tab left
  open doesn't hold them up.
- **Argo CD**: the Deployments have no `replicas` in git and the Applications ignore `/spec/replicas`
  (`RespectIgnoreDifferences=true`), otherwise self-heal would undo every scale.
- **Traefik**: `allowEmptyServices` is on by default in chart 40.x (503, not 404, while a Service has no endpoints), so the router
  and its Middleware stay alive while the app is at 0.

## What to know

- **Sablier restart = sessions lost.** No `--storage.file`, and `provider.auto-stop-on-startup` (default true) stops every labelled
  workload that Sablier didn't start. A Sablier restart (or a reboot) stops the three apps; the next request wakes them.
  After a reboot that's what we want anyway.
- **Started by hand stays up**: `kubectl scale --replicas=1` outside Sablier is not stopped (no `auto-stop-externally-started`) until
  a request through Traefik opens a session and it expires, or Sablier restarts.
- **Non-browser clients** (API, scripts) get the HTML waiting page instead of the app while it starts.
- **Sablier down**: the Middleware returns 500 (`failOpen: false`) for these three apps only; other routes don't use the plugin.
- **Plugin upgrade**: replace the files in `cluster/base/sablier-plugin/` (`.traefik.yml` without the icon/banner lines), push, then
  `kubectl -n kube-system rollout restart deploy traefik` (a ConfigMap change doesn't restart Traefik).
- `cluster/base/traefik-config.yaml` is also copied to `/var/lib/rancher/k3s/server/manifests/` (Phase 4): keep both identical.

## Add an app

1. Deployment: `labels: { sablier.enable: "true", sablier.group: <app> }`, remove `replicas`, keep a readinessProbe.
2. Middleware `<app>-sablier` (copy one from `apps/openwebui/openwebui.yaml`), add it to the IngressRoute's `middlewares`.
3. Argo Application: `ignoreDifferences` on the Deployment's `/spec/replicas` + `syncOptions: [RespectIgnoreDifferences=true]`.
4. Check nothing polls the app through Traefik (blackbox, widgets), or it never sleeps.

## Check

- `kubectl -n apps get deploy grampsweb grampsweb-celery openwebui firefox guacamole guacd`: `0/0` when asleep.
- Open the app: waiting page, then the app (~10-30 s). `kubectl -n infra logs deploy/sablier` shows the start and, 30 min after
  the last request, the stop.
- `kubectl -n argocd get applications apps-gramps apps-openwebui apps-firefox apps-guacamole`: Synced while scaled to 0.

Rollback: remove the Middleware from the IngressRoutes, `kubectl -n apps scale deploy <app> --replicas=1`, then delete Sablier and the
labels (`prune: false`: Middlewares and Sablier objects are deleted by hand).
