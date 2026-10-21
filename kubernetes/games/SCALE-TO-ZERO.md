# Minecraft: scale to zero when nobody plays (plan, not applied)

Written 2026-10-21. Status: **proposal**, nothing changed on the cluster or in the manifests yet.

## Why

State measured 2026-10-21 with the server auto-paused (java `SIGSTOP`ed by `autopause-daemon.sh`):

| | paused today | after the change (asleep) |
|---|---|---|
| RAM | **2.3 GiB** (java RSS, heap stays committed) | ~30-40 MiB (mc-router + BlueMap nginx) |
| CPU | ~25m (`mc-health` exec probe every 10 s, autopause loop, knockd) | ~1m |

Autopause stops ticking but keeps the whole JVM resident. Players are rare (mostly one or two players, a few
sessions a day), and Paper starts in ~17 s (`Done (16.537s)`), so a cold start is cheap.

## Decisions (asked 2026-10-21)

- Wake-up: **mc-router** in front, the server scales `replicas` 0 ↔ 1.
- Idle delay: **10 min** (same as today's `AUTOPAUSE_TIMEOUT_*`).
- BlueMap (`minecraft.fgdou.ovh`): **stays online**, served by a separate nginx (changed 2026-10-21, see "BlueMap without the server").
- Scope: idle only. In-game CPU tuning (simulation distance, chunk pre-generation, spark) is left for later.

## Target design

```
player ──► 10.0.0.2:25566 (LoadBalancer mc-router) ──► mc-router ──► Service minecraft:25565 ──► StatefulSet minecraft (0 or 1 pod)
                                                          │
                                                          └─ watches Services, patches statefulsets/scale
```

- **mc-router** (`itzg/mc-router`, Deployment in `games`), args:
  `-in-kube-cluster -kube-namespace games -auto-scale-up -auto-scale-down -auto-scale-down-after 10m`
  plus `-auto-scale-asleep-motd "Asleep: join to wake me up"` and `-auto-scale-loading-motd "Starting, reconnect in ~30 s"`.
  Image pinned `tag@sha256`, `IfNotPresent`, `enableServiceLinks: false`, a TCP readinessProbe, small requests
  (e.g. `cpu: 10m`, `memory: 32Mi`, limit `64Mi`).
- **RBAC** (Role + RoleBinding + ServiceAccount, namespace `games`): `services` watch/list; `statefulsets` watch/list/patch;
  `statefulsets/scale` get. Re-check the README of the pinned version when implementing.
- **Service `mc-router`**: `type: LoadBalancer`, port 25566 → 25565. It takes over the port of today's `minecraft` LB.
- **Service `minecraft`**: becomes `ClusterIP` (port 25565) with annotations
  `mc-router.itzg.me/externalServerName: mc.fgdou.ovh` (any name works) and `mc-router.itzg.me/defaultServer: "true"`
  (players who connect by IP or another hostname are still routed).
  Optionally `mc-router.itzg.me/autoScaleWaitTimeout: "30s"` (the client gives up after 30 s anyway).
- **Deployment `minecraft` → StatefulSet `minecraft`**: mc-router only scales StatefulSets. `metadata.name` and
  `spec.serviceName` must both be `minecraft`, or scaling never triggers. No `volumeClaimTemplates`: it keeps
  mounting the existing PVC `minecraft` (PV `games-minecraft`, unchanged).
- **Container env**: drop `ENABLE_AUTOPAUSE` and every `AUTOPAUSE_TIMEOUT_*` (knockd and autopause make no sense behind a proxy;
  mc-router counts connections by itself). `MAX_TICK_TIME=-1` and `JVM_DD_OPTS=disable.watchdog:true` were there for autopause
  and can go too (keeping them is harmless). `STOP_SERVER_ANNOUNCE_DELAY` can go to `0`: nobody is online at scale-down.
- `bluemap` IngressRoute now points to the nginx below instead of the server.

## BlueMap without the server

BlueMap is two separate things, and only the first one needs Minecraft:

1. **Renderer** (the plugin inside Paper): reads the world and writes the results to disk. With `storage-type: file`
   (`plugins/BlueMap/storages/file.conf`) everything lands in `/data/minecraft/bluemap/web/`:
   - `index.html`, `assets/`, `lang/`, `settings.json`: the web app (static JS, written by the plugin, `webapp.conf` `webroot`);
   - `maps/<map>/tiles/0/…/*.prbm.gz`: hi-res 3D tiles, gzip-compressed (`compression: gzip`), ~70 k files;
   - `maps/<map>/tiles/1..n/…/*.png`: low-res tiles;
   - `maps/<map>/settings.json`, `textures.json.gz`;
   - `maps/<map>/live/markers.json`, `players.json`: live data, also written to disk (`players.json` is `{}` when nobody plays).
2. **Web server** (the plugin's built-in one on 8123): only serves those files plus `live/`. Any static server can do it.

So the map stays readable while the server sleeps; only **new renders** and **live player positions** need the server, and those
only matter while someone plays anyway.

nginx needs 3 BlueMap-specific rules (from BlueMap's "external webserver / file storage" docs, re-check them for 5.x when implementing):

```nginx
server {
  listen 8080;
  root /bluemap;                     # = /data/minecraft/bluemap/web, mounted read-only

  # hi-res tiles are stored as .prbm.gz: serve the .gz file with Content-Encoding: gzip
  location ~* ^/maps/[^/]*/tiles/ {
    gzip_static always;
    error_page 404 = @empty;           # tile not rendered yet → 204, the web app shows nothing instead of an error
  }
  location ~* ^/maps/[^/]*/textures\.json$ { gzip_static always; }
  location @empty { return 204; }

  # live data: ask the plugin while the server runs, otherwise the copy on disk
  location ~* ^/maps/[^/]*/live/ {
    proxy_pass http://bluemap-live.games.svc.cluster.local:8123;
    proxy_connect_timeout 1s;
    proxy_intercept_errors on;
    error_page 502 503 504 = @disk;
  }
  location @disk { try_files $uri =204; }
}
```

(`gzip_static` is in the official `nginx` image. `resolver` is needed if `proxy_pass` uses a variable; with a fixed name nginx
resolves it once at start: use the Service ClusterIP name as above, it exists even with no endpoints.)

Kubernetes side:
- `Deployment bluemap-web`: `nginx` (or `nginx-unprivileged`) pinned `tag@sha256`, `IfNotPresent`, config in a ConfigMap, readinessProbe on `/`,
  ~10 MiB RAM.
- Volume: the **same PVC `minecraft`**, `readOnly: true`, `subPath: bluemap/web`. A `local` RWO PV can be mounted by several pods
  on the same node, so no new PV. The files are `664`/`775` (uid 1000), so nginx can read them as any uid.
- `Service bluemap` → selects the nginx pod (port 8080). A new `Service bluemap-live` → the Minecraft pod's 8123 (only for `live/`).
- Plugin: keep its webserver on (`webserver.conf enabled: true`) for the `live/` proxy. If live positions aren't worth it,
  set `enabled: false` and drop the `live/` proxy: nginx then serves the `live/*.json` files from disk.

What to know:
- **Render lag.** Rendering only happens while the server runs, and with `render-thread-count: 1` it can still be behind when the server
  goes to sleep. The pending work is saved (`bluemap/tasks.dat`) and resumes at the next start, so chunks changed just before
  scale-down appear on the map at the next session. If that bothers you: `bluemap-cli` as a CronJob (`-r` = render, same config and
  storage) can render with the server stopped. Not needed to start with.
- **Never run the CLI while the server is up** (two renderers writing the same storage). If added, the CronJob must check that the
  StatefulSet is at 0 replicas.

## Traps to handle

1. **Argo CD self-heal vs. mc-router.** If `spec.replicas` is in git, Argo resets it within seconds every time mc-router scales.
   - Leave `spec.replicas` **out** of the StatefulSet manifest (the API sets 1 at creation, then nobody in git owns it), and
   - add to `argocd/apps/games.yaml`, to be sure:
     ```yaml
     spec:
       ignoreDifferences:
         - { group: apps, kind: StatefulSet, name: minecraft, jsonPointers: [/spec/replicas] }
       syncPolicy:
         syncOptions: [RespectIgnoreDifferences=true]
     ```
2. **`prune: false`**: the old `Deployment minecraft` is not deleted when removed from git. Delete it by hand
   (`kubectl -n games delete deploy minecraft`) **before** the StatefulSet starts, or two servers fight over the same world (RWO on
   a single node does not stop that). Order: scale the Deployment to 0 → push → delete the Deployment.
3. **Graceful stop: an existing bug, fix it whatever you decide.** The pod has the default `terminationGracePeriodSeconds: 30`, but
   `mc-server-runner` runs with `--stop-duration 60s --stop-server-announce-delay 10s`. A slow save gets SIGKILLed (that's what
   happened during the Docker → k3s move, README Phase 4.4). Scale-down makes this happen several times a day, so set
   `terminationGracePeriodSeconds: 90`.
4. **Client experience on wake-up.** Server list: asleep MOTD. Join: mc-router scales to 1 and holds the connection up to
   `autoScaleWaitTimeout`. Pod start + JVM + ~17 s Paper ≈ 25-35 s, right at the client's 30 s timeout: the first
   join may fail with "timed out", and the player reconnects. Tell your players.
5. **Player IPs.** Behind the proxy, Paper sees mc-router's pod IP (`ban-ip`, logs). Already only partly real today (klipper LB,
   `externalTrafficPolicy: Cluster`). If you care: mc-router `-use-proxy-protocol` +
   `proxies.proxy-protocol: true` in `config/paper-global.yml`, set both at once or every connection fails.
6. **Readiness.** Keep the `mc-health` readinessProbe on the server: it is what tells mc-router the backend is ready.

## Side benefits

- The restic backup (Sun 02:00) will almost always copy `/data/minecraft` while the server is stopped → a consistent world.
- After a reboot the StatefulSet keeps its last `replicas` (usually 0): no Minecraft/Paper start at boot.

## Rollout (when you decide to apply)

1. `kubectl -n games scale deploy minecraft --replicas=0` (pause Argo first: `argocd app set games --core --sync-policy none`),
   wait for `Saving chunks`/exit in the logs.
2. Push: StatefulSet + mc-router + RBAC + Services + `games.yaml` ignoreDifferences. `kubectl kustomize kubernetes/games >/dev/null` first.
3. `kubectl -n games delete deploy minecraft`, then re-enable Argo (`--sync-policy automated --self-heal`).
4. Check:
   - `kubectl -n games get sts,pods,svc`: `mc-router` LB on 10.0.0.2:25566, `minecraft` pod Ready.
   - Join → leave → after 10 min `kubectl -n games get sts minecraft` shows `0/0`, and Argo stays Synced (no fight over replicas).
   - Server list shows the asleep MOTD; join wakes it; log shows a clean `Saving chunks for level` on each scale-down.
   - `kubectl -n games top pod`: only mc-router and bluemap-web left while asleep.
   - `https://minecraft.fgdou.ovh` while asleep: map loads, 3D tiles render (browser dev tools: `.prbm` with `Content-Encoding: gzip`,
     missing tiles `204`, no `404`/`502`).
5. Update README "Migration notes per stack" (minecraft) and PROGRESS.md.

Rollback: delete StatefulSet/mc-router, `git revert`, and the old Deployment comes back from git (data untouched, PV `Retain`).

## Not chosen (for the record)

- **Tune the paused JVM** (G1 periodic GC, `-Xms` low, `spawnChunkRadius 0`): maybe 2.3 → 1-1.5 GiB, CPU unchanged.
- **lazymc** in the pod: kills only java and the client waits and joins automatically (nicer UX), but it means a wrapper or custom image
  around the itzg one, and the pod and its probes stay up.
- **itzg `ENABLE_AUTOSTOP`** alone: the container exits and Kubernetes restarts it right away; it only works with something to scale it.
