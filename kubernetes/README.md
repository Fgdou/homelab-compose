# kubernetes/

Kubernetes manifests for the NAS (k3s, single node `nas`), replacing the Docker compose files in the repository root.
The plan and every decision behind it are in [MIGRATION.md](MIGRATION.md). Secrets: [OPENBAO-KEYS.md](OPENBAO-KEYS.md).

Status: **Phase 4 done** (2026-10-21) — k3s `v1.36.5+k3s1` runs every stack (Traefik on 80/443/22, mail, bind9, games); Docker stays enabled but empty, as the fallback. Argo CD follows the `main` branch over HTTPS (`kube` merged 2026-10-21); OpenBao, External Secrets, cert-manager, Image Updater. Phase 5 step 1 (readiness probes) done 2026-10-21; step 2 (Jellyfin VAAPI) optional (MIGRATION.md §11). UIs (LAN only, authentik OIDC): `https://bao.fgdou.ovh`, `https://argocd.fgdou.ovh`.

## Layout

| Folder | Content | Argo CD Application |
|---|---|---|
| `bootstrap/` | k3s config, OpenBao import script, Docker Traefik bridge example | none (used by hand) |
| `argocd/root.yaml` | root app-of-apps, reads only `argocd/apps/` | applied by hand once |
| `argocd/available/` | one ready-made Application per folder below | — |
| `argocd/apps/` | **enabled** Applications only (the gate) | `root` |
| `cluster/base/` | namespaces, storage classes, Traefik `HelmChartConfig`, Traefik metrics Service | `cluster` |
| `cluster/secret-store/` | `ClusterSecretStore` (OpenBao), cloudflare ExternalSecret | `cluster-secret-store` |
| `cluster/certs/` | Let's Encrypt `ClusterIssuer`, wildcard certificates, Traefik default `TLSStore` | `cluster-certs` |
| `platform/openbao/` | Helm values + PV + UI route | `platform-openbao` |
| `platform/external-secrets/`, `platform/cert-manager/` | Helm values | `platform-external-secrets`, `platform-cert-manager` |
| `platform/argocd/` | Helm values + UI route | `platform-argocd` |
| `platform/image-updater/` | Helm values + `ImageUpdater` rule (mariage, todoapp) | `platform-image-updater` |
| `platform/local-path/` | local-path-provisioner with `data-dynamic` / `films-dynamic` | `platform-local-path` |
| `<namespace>/` | one folder per namespace (`databases`, `authentik`, `monitoring`, `media`, `home`, `immich`, `dawarich`, `gitea`, `mail`, `nextcloud`, `projects`, `games`, `infra`, `ciq`) | same name |
| `databases/redis/` | shared Redis (no persistence) for every migrated app, split out of `databases` so it runs before Postgres (group 5) | `databases-redis` |
| `apps/<app>/` | namespace `apps` split per app (actual, vaultwarden, trilium, mealie, lubelogger, speedtest, openwebui, firefox, meshcentral, gramps, warracker, guacamole): each folder holds the app, its PV/PVC and its ExternalSecret, so apps migrate one at a time | `apps-<app>` |

`authentik` and `immich` are official Helm charts (`values.yaml`) plus plain resources (`kustomization.yaml`) in the same Application. Everything else is plain YAML + Kustomize.

## Conventions

- **Images** are pinned as `tag@sha256:digest`, to the exact image running on Docker on 2026-10-20. A trailing comment gives the app version when the tag doesn't. Exception: `projects/kustomization.yaml` `images:` (rewritten by Image Updater).
- **Volumes**: one static `local` PV per existing folder, bound to its PVC with `volumeName` (PV name `<namespace>-<pvc>`). Classes: `data` (/data), `films` (/films), `nvme` (postgres only). Several mounts of one folder use `subPath`. Reclaim policy is always `Retain`.
- **Secrets**: one `ExternalSecret` per app, reading `kv/<namespace>/<app>` (and `kv/shared` for shared values). Property names are the env var names, used with `envFrom`.
- **Stateful Deployments** use `strategy: Recreate`, so two pods never share a data folder.
- **Routing**: `IngressRoute` on `websecure`; apps that had `authentik@docker` use the `authentik/authentik` Middleware.
- Labels: `app.kubernetes.io/name: <app>` on every workload and Service selector.

## Validate (no cluster needed)

```sh
for d in cluster/* platform/* databases databases/redis authentik monitoring media home immich dawarich gitea mail nextcloud apps/* projects games infra ciq; do
  [ -f $d/kustomization.yaml ] && kustomize build $d > /tmp/render-$(echo $d | tr / -).yaml
done
helm template authentik authentik/authentik --version 2026.8.4 -n authentik -f authentik/values.yaml > /tmp/render-chart-authentik.yaml
helm template immich immich/immich --version 0.12.0 -n immich -f immich/values.yaml > /tmp/render-chart-immich.yaml
kubeconform -strict -summary -skip CustomResourceDefinition,ImageUpdater \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/render-*.yaml
```

Last run (2026-10-20): 22 Kustomize folders and 8 charts render; 470 resources valid, 0 invalid. `ImageUpdater` is skipped because the public schema is older than the CRD of chart 1.3.2 (which only requires `applicationRefs`).

## Bootstrap (Phase 2)

Order matters: OpenBao and External Secrets must not depend on secrets served by OpenBao.

0. Host tuning (done 2026-10-20, found during Phase 3): `sudo cp bootstrap/sysctl-90-inotify.conf /etc/sysctl.d/90-inotify.conf && sudo /usr/sbin/sysctl -p /etc/sysctl.d/90-inotify.conf` — k3s + Docker exhausted root's 128 inotify instances (lubelogger crashed, Docker's containerd logged `inotify fd: too many open files`).
1. Install k3s `v1.36.5+k3s1` (done 2026-10-20):
   ```sh
   sudo mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/server/manifests /data/openbao /data/k8s /films/k8s
   sudo install -m 0644 bootstrap/k3s-config.yaml /etc/rancher/k3s/config.yaml
   # Traefik override BEFORE the first start, otherwise ServiceLB grabs 80/443 from Docker Traefik
   sudo install -m 0600 cluster/base/traefik-config.yaml /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
   curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -
   sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config && chmod 600 ~/.kube/config
   export KUBECONFIG=~/.kube/config   # k3s' kubectl otherwise reads the root-only /etc/rancher/k3s/k3s.yaml
   ```
   k3s re-applies `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` on every start: keep it identical to `cluster/base/traefik-config.yaml` (Phase 4 port change included).
2. `kubectl apply --server-side -k cluster/base` and `kubectl apply --server-side -k platform/local-path` (done 2026-10-20). Server-side apply leaves the k3s-managed Traefik `HelmChartConfig` untouched when it is identical.
3. Install the platform charts with Helm, same versions and values as `argocd/available/platform-*.yaml` (OpenBao, External Secrets, cert-manager), plus `kubectl apply -k platform/openbao` for its PV.
4. OpenBao (done 2026-10-20 for OpenBao itself; ESO and cert-manager charts are steps 4–5). Helm v4.3.1 is installed in `/usr/local/bin`.
   ```sh
   sudo chown 100:1000 /data/openbao && sudo chmod 0770 /data/openbao      # pod runs as uid 100 / fsGroup 1000
   kubectl apply --server-side -k platform/openbao                           # PV (+ IngressRoute, inert until authentik exists)
   helm repo add openbao https://openbao.github.io/openbao-helm
   helm install openbao openbao/openbao --version 0.30.4 -n openbao -f platform/openbao/values.yaml
   kubectl -n openbao exec openbao-0 -- bao operator init -format=json > openbao-init.json   # 5 shares, threshold 3 → Vaultwarden, then shred
   ```
   Then unseal (3 keys), `bao login -no-print -` (token on stdin), `bao secrets enable -version=2 -path=kv kv`, `bao auth enable kubernetes`, `bao write auth/kubernetes/config kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT`, policy `external-secrets` = `read` on `kv/data/*`, role `external-secrets` bound to `external-secrets/external-secrets` (ttl 1h). Then `bootstrap/openbao-import.sh --dry-run`, then without `--dry-run` (23 paths). Finally delete the root token from the pod: `kubectl -n openbao exec openbao-0 -- rm /home/openbao/.vault-token`.
   The pod stays `0/1 Ready` while sealed: its readiness probe is `bao status`, which exits 2 when sealed.

### OpenBao login (OIDC with authentik)

- UI: `https://bao.fgdou.ovh` (LAN only: `lan-only` ipAllowList on the Docker Traefik bridge router in `/data/traefik/config.yaml`) → method **OIDC**, role empty (default `authentik`) → authentik login.
- authentik side: `authentik/blueprints/openbao.yaml` (provider `OpenBao`, client ID `openbao`, application restricted to the `admin` group). `ak apply_blueprint` only accepts files under `/blueprints`; it was applied with `Importer.from_string(...).apply()` in `ak shell`.
- OpenBao side: `auth/oidc` (discovery `https://auth.fgdou.ovh/application/o/openbao/`, client secret copied from authentik, never committed), role `authentik` (only redirect URI `https://bao.fgdou.ovh/ui/vault/auth/oidc/oidc/callback`, `groups_claim=groups`, base policy `default`, ttl 8h / max 24h), policy `admin` (everything), external identity group `admin` (policy `admin`) with alias `admin` on the oidc mount → **every member of the authentik `admin` group is OpenBao admin**.
- No localhost redirect URI, so no `bao login -method=oidc` from the CLI: copy a token from the UI (user menu → *Copy token*) and `bao login -` it.
- Break-glass (authentik down): `kubectl -n openbao port-forward svc/openbao 8200`, then `bao operator generate-root` with 3 unseal keys.

### Unseal after a reboot or pod restart

`bao operator unseal` does **not** read stdin (`-` is taken as the key). Run it 3 times, pasting a different key from Vaultwarden at the hidden prompt each time:

```sh
kubectl -n openbao exec -it openbao-0 -- bao operator unseal
```
5. External Secrets (done 2026-10-20): `helm repo add external-secrets https://charts.external-secrets.io`, `helm install external-secrets external-secrets/external-secrets --version 2.13.0 -n external-secrets -f platform/external-secrets/values.yaml --wait`, then `kubectl apply --server-side -k cluster/secret-store` → `clustersecretstore/openbao` Ready, `cert-manager/cloudflare` SecretSynced.
   cert-manager (done 2026-10-20): `helm repo add jetstack https://charts.jetstack.io`, `helm install cert-manager jetstack/cert-manager --version v1.21.2 -n cert-manager -f platform/cert-manager/values.yaml --wait`, then `kubectl apply --server-side -k cluster/certs` → both wildcard `Certificate`s Ready in ~3 min (DNS01), Traefik serves them on 8443 by SNI.
   authentik Middleware (done 2026-10-20): `kubectl apply --server-side -f authentik/middleware.yaml` (only this file). Interim target `http://10.0.0.2:9000` = Docker `authentik_server`, published by a `ports:` entry in `/data/compose/authentik.yml`.
   Original note: Then `kubectl apply -k cluster/certs` — wait for both wildcard certificates to be `Ready`.
6. Argo CD (done 2026-10-20): repo is public → `repoURL: https://github.com/Fgdou/homelab-compose.git`, no repository credentials; Applications followed `targetRevision: kube` during the migration; since 2026-10-21 (kube merged) they follow `main`.
   - authentik: `authentik/blueprints/argocd.yaml` (applied like the OpenBao one), client secret → OpenBao `kv/argocd/argocd-oidc` → ExternalSecret `argocd/argocd-oidc` (label `app.kubernetes.io/part-of: argocd`).
   - `helm repo add argo https://argoproj.github.io/argo-helm`, `helm install argocd argo/argo-cd --version 10.10.5 -n argocd -f platform/argocd/values.yaml --wait`, `kubectl apply --server-side -k platform/argocd`.
   - `helm install argocd-image-updater argo/argocd-image-updater --version 1.3.2 -n argocd -f platform/image-updater/values.yaml --wait`, `kubectl apply --server-side -k platform/image-updater`.
   - Docker Traefik bridge router `k3s-argocd` (LAN only) in `/data/traefik/config.yaml`.
   - `kubectl apply --server-side -f argocd/root.yaml`.
7. `git mv` the `cluster*` and `platform-*` Applications to `argocd/apps/`, commit, push (done 2026-10-20, commit `11c032d`). Before syncing, `argocd app diff <app> --core` showed only the added `argocd.argoproj.io/tracking-id` annotations; then `argocd app sync <app> --core` one by one (no pod restarted).
   - `argocd` CLI v3.5.5 is in `/usr/local/bin`. `--core` mode talks to the cluster with your kubeconfig and needs the current namespace to be `argocd` (`kubectl config set-context --current --namespace=argocd`, or a copy of the kubeconfig).

8. Docker Traefik bridge (done 2026-10-20), see below.

### Docker Traefik bridge (until the Phase 4 cutover)

Docker Traefik keeps 80/443 and forwards the hostnames of migrated stacks to k3s Traefik:

```
browser → Docker Traefik :443 (router in /data/traefik/config.yaml) → k3s Traefik 10.0.0.2:8443 (IngressRoute) → pod
```

- Live file: `/data/traefik/config.yaml` (file provider, watched: no restart). It holds the `k3s` service (`https://10.0.0.2:8443`, `passHostHeader`, serversTransport `k3s` with `insecureSkipVerify` — reached by IP, traffic stays on the NAS), the `lan-only` ipAllowList (`10.0.0.0/16`) and one router per hostname. Template: `bootstrap/docker-traefik-bridge.yaml`.
- Add a hostname: copy a router block (`rule: Host(...)`, `entryPoints: [websecure]`, `service: k3s`, `tls: {}`, plus `middlewares: [lan-only]` only for admin UIs). Edit in place (`sudo tee`, not `install`/`mv`: replacing the file makes Traefik briefly log "no such file").
- Real client IP: Docker Traefik's container reaches k3s Traefik masqueraded to `10.42.0.1` (cni0 gateway). k3s Traefik's `websecure` trusts `X-Forwarded-For` from `10.42.0.1/32` only (`cluster/base/traefik-config.yaml`), so pods get the real client in `X-Real-Ip` / `X-Forwarded-For`. Side effect: a process on the NAS itself calling `:8443` directly could inject `X-Forwarded-For` (remote clients can't: Docker Traefik overwrites it).
- Verified with a whoami test app: real client IP, `X-Forwarded-Proto: https`, WebSocket upgrade 101, port 80 → 443 redirect by Docker Traefik.
- Bridge ended at the Phase 4 cutover (2026-10-21): k3s Traefik owns 80/443/22, `/data/traefik/config.yaml` is no longer used. Last bridged set: `bao.fgdou.ovh`, `argocd.fgdou.ovh` (both `lan-only`), `speedtest.fgdou.ovh` (public), `firefox.fgdou.ovh` (public router, authentik forward-auth in k3s), `actual.fgdou.ovh` (public), `trilium.fgdou.ovh` (public router, forward-auth in k3s), `lubelogger.fgdou.ovh` (public router, forward-auth in k3s), `mealie.fgdou.ovh` (public), `gramps.fgdou.ovh` (public), `vaultwarden.fgdou.ovh` (public), `ai.fgdou.ovh` (openwebui, public), `meshcentral.fgdou.ovh` (public; agents over WebSocket), `sr.fgdou.ovh`, `mariage.fgdou.ovh`, `todo.fgdou.ovh`, `immich.fgdou.ovh`, `dawarich.fgdou.ovh`, `ciq-panier.fr` (public), `gitea.fgdou.ovh` (public) + TCP router `k3s-gitea-ssh` (ssh :22 → 10.0.0.2:2222), `films.fgdou.ovh` (jellyfin, public), `music.fgdou.ovh` (navidrome; forward-auth in k3s except `/rest`, `/share`), `jellyseerr.fgdou.ovh` (public), `radarr`, `sonarr`, `prowlarr`, `qbittorrent`, `lidarr`, `musiseerr`, `slskd` `.fgdou.ovh` (public routers, forward-auth in k3s), `prometheus.fgdou.ovh` (public router, forward-auth in k3s), `grafana.fgdou.ovh`, `ntfy.fgdou.ovh` (public), `adminer.fgdou.ovh` (`lan-only`, forward-auth in k3s), `auth.fgdou.ovh` (authentik, public), `nextcloud.fgdou.ovh` (public), `guacamole.fgdou.ovh` (public), `warracker.fgdou.ovh` (public), `dash.fgdou.ovh` (homeassistant, public), `zigbee2mqtt.fgdou.ovh` (public router, forward-auth in k3s), `musicassistant.fgdou.ovh` (public). The `authentik@file` middleware's target, k3s LoadBalancer `authentik-server-docker` on `10.0.0.2:9000` (`authentik/docker-bridge.yaml`), was removed 2026-10-21.

### Migrated stacks (Phase 3)

| Date | App | Application | Docker removed | Notes |
|---|---|---|---|---|
| 2026-10-20 | speedtest | `apps-speedtest` | `docker compose -f speedtest.yml rm -sf speedtest` | 17 s switch; real client IP OK |
| 2026-10-20 | firefox | `apps-firefox` | `docker compose -f firefox.yml rm -sf firefox` | 62 s switch (image pull); forward-auth → Docker authentik OK; profile not kept (by choice) — old anonymous Docker volume `e589f6f8…` still on disk, delete with `docker volume rm` when you want |
| 2026-10-20 | actual | `apps-actual` | `docker compose -f actual_budget.yml rm -sf actual_server` | 14 s switch, then **~2 min crash loop**: the Service `actual` injected `ACTUAL_PORT=tcp://…` (Kubernetes service links), which Actual reads as its port → fixed with `enableServiceLinks: false` (`d77e706`). Data identical to the pre-switch snapshot; `bootstrapped: true`, OpenID login. |
| 2026-10-20 | trilium | `apps-trilium` | `docker compose -f trilium.yml rm -sf trilium` | 26 s switch. No own auth (`NOAUTHENTICATION=true`): forward-auth verified (302 on `/` and `/api`, LAN and non-LAN). db=234, consistency checks passed. Trusted proxy now `10.42.0.0/16` (the Docker container had a typo, `72.18.0.21/16`). |
| 2026-10-20 | lubelogger | `apps-lubelogger` | `docker compose -f lubelogger.yml rm -sf app` | 18 s switch, then **~2 min crash loop**: root had exhausted `fs.inotify.max_user_instances` (128; k3s + containerd shims) → raised to 1024 (`bootstrap/sysctl-90-inotify.conf`). Data and DataProtection keys unchanged; OIDC via public `auth.fgdou.ovh` URLs. |
| 2026-10-20 | mealie | `apps-mealie` | `docker compose -f mealie.yml rm -sf mealie` | 26 s switch. ExternalSecret synced alone first (`argocd app sync --resource`) and compared with the running container before stopping it. Same DB; OIDC redirect OK; SMTP to Docker mailserver (`mail.fgdou.ovh:587` → 10.0.0.2) OK from the pod. |
| 2026-10-20 | openwebui | `apps-openwebui` | `docker compose -f ai.yml rm -sf openwebui` | 98 s switch (big image pull) + ~60 s app startup (502 until it listens: no readiness probe). `WEBUI_SECRET_KEY` was empty → the container had generated `/app/backend/.webui_secret_key` (not persisted); its value was copied to OpenBao `kv/apps/openwebui` so sessions survived (a logged-in user kept working). 3 users / 395 chats; backend = OpenAI API only. |
| 2026-10-20 | meshcentral | `apps-meshcentral` | `docker compose -f meshcentral.yml rm -sf meshcentral` | 23 s switch. **Manifest fix**: MeshCentral serves plain HTTP on 443 (`TLSOffload`), the IngressRoute said `scheme: https` → `http`, port names `https` → `http`. Bridge router added *before* the pod started so `certUrl` (`meshcentral.fgdou.ovh:443`) loads Docker Traefik's public cert: SHA384 `5b94c01c…cf76cab` = the cert agents see. `config.json` rewritten by DYNAMIC_CONFIG with no changed key. Web 200, `/agent.ashx` WebSocket 101; agents reconnected (confirmed). Restart it at the Phase 4 cutover (new public cert). |
| 2026-10-20 | gramps | `apps-gramps` | `docker compose -f gramps.yml rm -sf grampsweb grampsweb_celery` | ~1 min switch. Secret compared with the running container first. Web + celery on `redis.databases` (db 0 broker/results, db 1 rate limit); OIDC redirect OK, tree and login checked by the user. |
| 2026-10-20 | vaultwarden | `apps-vaultwarden` | `docker compose -f vaultwarden.yml rm -sf VaultWarden` | ~30 s switch. Secret compared first; DB integrity ok, 6 users / 1841 ciphers before and after; WebSocket notifications 101. `config.json` overrode the env (`DOMAIN`, `SIGNUPS_ALLOWED`, `ADMIN_TOKEN`) and had **signups enabled** → those 3 keys removed so the env applies (signups now off). Saving in `/admin` rewrites them into `config.json` and the override comes back. |
| 2026-10-20 | sr, mariage, todoapp | `projects` | `docker compose -f projects.yml rm -sf sr mariage todoapp` | 14 s switch (images already in containerd; mariage pulls anonymously from `gitea.fgdou.ovh`). Secret compared first. todoapp: OIDC login + task create OK, data started empty (emptyDir by decision; old Docker volume `todoappdata` still on disk). sr: `/data/sr/leaderboard` was empty, app created `leaderboard.json`. **No auto-update yet**: Image Updater skips both images until it has git write access. |
| 2026-10-20 | immich | `immich` | `docker compose -f immich.yml rm -sf immich-server immich-machine-learning`, then `stop -t 60` + `rm` of `immich_database` (clean Postgres shutdown) | 26 s switch (images already in containerd). Secret compared first. Same row counts before/after (57466 assets, 4 users, 13 albums, 60932 faces); v3.3.3 finds the library at `/usr/src/app/upload` (`.immich` markers OK); ML `pong` from the server; OAuth authorize 201. Redis: `redis.databases` **db 2** (`REDIS_DBINDEX`, db 0-1 = gramps). ML got the whole shared `.env` via `env_file` but uses none of it. Model cache is emptyDir (first ML job re-downloads models). |
| 2026-10-20 | dawarich | `dawarich` | `docker compose -f dawarich.yaml rm -sf dawarich_sidekiq dawarich_app`, then `stop -t 60` + `rm` of `dawarich_db` | 68 s switch (Rails boot + migration check). 4 secrets compared first (incl. `SECRET_KEY_BASE`). Same row counts (281909 points, 2 users, 1 import, 5363 visits). Redis defaults (db 0-3) collided with gramps/immich → `RAILS_CACHE_DB=3`, `RAILS_JOB_QUEUE_DB=4`, `RAILS_WS_DB=5`, `RACK_ATTACK_REDIS_DB=6`. Sidekiq queues were empty; 1 retry + 3 dead jobs left in Docker's redis. Health ok, OIDC login, Sidekiq cron jobs registered. |
| 2026-10-20 | ciq | `ciq` | `docker compose -f ciq.yml rm -sf ciq-wordpress ciq-ddclient`, then `stop -t 60` + `rm` of `ciq-mysql` (clean MySQL shutdown) | ~20 s switch (images already in containerd). Secret compared first (hashes). Same row counts in all 37 tables (153 posts, 4 users, 51 comments, 257 options); `/` same size before/after. Bridge on the `ciq-panier.fr` cert of Docker Traefik. ddclient updated `ciq-panier.fr` from the pod. |
| 2026-10-20 | gitea | `gitea` | `docker compose -f gitea.yaml rm -sf gitea gitea_runner` | ~10 s switch. Runner token compared first; SQLite integrity ok (3 repos, 2 users, 9 issues, 1 package). SSH bridged as a **TCP router** in `/data/traefik/config.yaml` (Docker Traefik :22 → k3s Traefik `ssh` :2222), same host keys. **Runner fix**: dind args starting with a flag made the entrypoint add `--host=tcp://0.0.0.0:2375` (collided with ours → crash loop, and would expose root docker to the cluster) → dind is now a native sidecar (startupProbe) on a unix socket in a shared emptyDir, which act_runner mounts into job containers (`docker/build-push-action`). Offline `Runner1` rows (ids 5-9) left from re-registrations. |
| 2026-10-21 | media (arr, jellyseerr, qbittorrent, flaresolverr, lidarr, musiseerr, slskd, soularr) | `media` | `docker compose -f torrent.yml rm -sf radarr sonarr prowlarr flaresolverr jellyseerr qbittorrent lidarr slskd soularr musiseerr` | ~3 min switch for the whole stack (with jellyfin and navidrome). 12 pins matched, 3 secrets compared first. SQLite integrity ok on every DB (211 movies, 97 series / 7152 episodes, 15 indexers, 86 artists, 149 requests). Internal links unchanged (same Service names); built-in tests OK (radarr/sonarr → qbittorrent, prowlarr → apps + flaresolverr; Whisparr fails: never deployed). musiseerr: 3 restarts at start (lidarr not ready yet). slskd logged in, peer port 50300 via ServiceLB. `dns: 1.1.1.1` of jellyseerr dropped (cluster DNS resolves TMDB and `films.fgdou.ovh`). Pre-existing: sonarr cannot write `/films/Films/series/Ted Lasso`, lidarr Spotify tokens expired. |
| 2026-10-21 | jellyfin | `jellyfin` | `docker compose -f jellyfin.yml rm -sf jellyfin` | First deployed in `media`, then split into its own namespace/Application (~30 s, `97eb909`). LDAP plugin → `10.0.0.2:6636` (Docker outpost published, interim). `jellyfin_exporter` (Docker) → `https://films.fgdou.ovh` (interim). iGPU mount does not work → software transcoding as before (MIGRATION.md §11 Phase 5 step 2). Pre-existing: stale LDAP plugin v20 folder fails to load (v22 used). |
| 2026-10-21 | navidrome | `navidrome` | `docker compose -f navidrome.yml rm -sf navidrome` | Same as jellyfin (split from `media`). 7873 tracks / 7 users; `/rest` and `/share` bypass authentik. To check: navidrome trusts `X-authentik-username` from any source (`ND_REVERSEPROXYWHITELIST=0.0.0.0/0`), and the bypass routes pass a client-sent header through. |
| 2026-10-21 | monitoring | `monitoring` | `docker compose -f monitoring.yml stop -t 60 prometheus grafana`, then `rm -sf` of the whole file (incl. cadvisor, not migrated) | ~1 min switch (Grafana up at +54 s). 9 pins matched, 6 secrets compared first. Docker Traefik recreated first to publish metrics on `10.0.0.2:8082` (12 s outage of every site), scraped next to k3s Traefik (certificate expiry alert). TSDB kept (30 days of history). Grafana DB integrity ok (8 dashboards, 7 alert rules, 2 users); datasource `http://prometheus:9090` and ntfy webhook `http://ntfy/` unchanged. cadvisor and dockerd metrics dropped (unused). Until 3.5: `authentik` target down, `pg_up 0` (accepted). Pre-existing: Strava plugin secret missing. |
| 2026-10-21 | postgres, adminer, pg-backups | `databases` | `docker compose -f postgres.yml rm -sf adminer pg_backups`, then `stop -t 60` + `rm` of `postgres` (clean shutdown) | 13 s switch. 3 pins matched, password compared first. Moved **alone** (not with its consumers, unlike the plan): authentik, nextcloud, guacamole, warracker stay on Docker and reach k3s through `postgres-bridge.yml` (socat named `postgres` on `nas` → fixed ClusterIP `10.43.54.32`; Docker containers can reach ClusterIPs), no config change. Same row counts before/after (authentik 20 users, nextcloud 42431 filecache rows, guacamole 10 connections, warracker 20 warranties). warracker's notification job failed once on stale pooled connections, fine from the next run. Manual `pg-backups` job OK (`/data/postgres_backups`). `pg_up 1`. Adminer: no host port any more, `adminer.fgdou.ovh` (`lan-only` + new authentik proxy provider "Adminer" on the embedded outpost). |
| 2026-10-21 | nextcloud | `nextcloud` | `docker compose -f nextcloud.yml rm -sf nextcloud` | 27 s switch, then ~4 min public 404 until the bridge router was added (the label router left with the container). Pin matched, secret compared first (install-time only: the real DB settings live in `config.php`). `config.php`: `dbhost` → `postgres.databases`, redis `host` → `redis.databases` (`redis.config.php` overrides it from `REDIS_HOST` anyway). Background jobs (mode `cron`) ran from the host crontab of `fgdou` (`docker compose exec … cron.php`): line removed, replaced by a `cron` sidecar running the image's `/cron.sh` (first run OK). Same row counts (42436 filecache, 5 users, 3 OIDC users, 21 shares); OIDC redirect to `auth.fgdou.ovh`, WebDAV 401 unauthenticated, checked by the user. Pre-existing: code on disk is **32.0.3** while the image is 33.0.5 (the custom command skips the entrypoint, so no auto-upgrade). Redis uses the default **db 0**, shared with gramps (keys are prefixed, no collision seen); give it its own `dbindex` later. |
| 2026-10-21 | guacamole (+ guacd) | `apps-guacamole` | `docker compose -f guacamole.yml rm -sf guacamole guacd` | 14 s switch. 2 pins matched, secret compared first. DB now `postgres.databases` directly (no bridge). Same rows (3 entities, 10 connections). OIDC login OK, checked by the user. Reachability from the pod network = from the host: nas and PC SSH answer; the libvirt VMs, PC VNC, plerin and vps were already unreachable from the host. `guacd`'s shell has no `/dev/tcp`: test with a busybox `nc` pod. |
| 2026-10-21 | authentik (server, worker, LDAP outpost) | `authentik` | `docker compose -f authentik.yml rm -sf server worker authentik_ldap` | ~80 s outage of login and forward-auth (whole SSO). 2 pins matched, both secrets compared first. Same commit: k3s Middleware → `authentik-server.authentik`, interim Docker `ports:` dropped. `authentik@docker` disappeared with the container → file middleware `authentik@file` in `/data/traefik/config.yaml` targeting a k3s LoadBalancer on `10.0.0.2:9000`; zigbee2mqtt recreated on it, the Traefik dashboard label is changed but only applies when Docker Traefik is recreated (no forward-auth on `traefik.fgdou.ovh` until then). Jellyfin `<LdapServer>` → `authentik-ldap.authentik` (pod restarted, LDAP login checked by the user). Prometheus `authentik` target up. Service-link env vars injected by the chart are ignored. Worker logged a `DockerException` from the old "Local Docker connection" outpost integration (no socket any more): deleted 2026-10-21 (no outpost used it). Forward-auth through `:9000` sees the Docker gateway `172.18.0.1` as client IP. |
| 2026-10-21 | warracker | `apps-warracker` | `docker compose -f warracker.yml rm -sf warracker` | 12 s switch. Pin matched, secret compared first. DB `postgres.databases` directly; 20 warranties before/after, uploads (subPath `warracker_uploads`) OK. OIDC `redirect_uri` is `http://` (app's nginx sends `X-Forwarded-Proto $scheme`), same as on Docker; authentik provider matches `https?://` by regex. One harmless gevent `AssertionError` at worker fork. Last Docker postgres consumer: `postgres-bridge.yml` removed (no client left in `pg_stat_activity`). |
| 2026-10-21 | homeassistant, zigbee2mqtt, mosquitto, musicassistant | `home` | `docker compose -f homeassistant.yml rm -sf homeassistant zigbee2mqtt mosquitto musicassistant` | 4 pins matched. HA `home-assistant_v2.db` and MA `library.db` `quick_check` ok (765073 states). HA and MA on `hostNetwork` so mDNS/SSDP reach the LAN (Chromecast, HomeKit 21063, MA streams 8097); side effect: HA 8123 and MA 8095 are now open on the LAN (no host firewall, left as is). zigbee2mqtt (pod network) gets the ConBee II via privileged + hostPath `/dev/ttyACM0`. HA's reverse-proxy settings live in `.storage/http` (UI): `10.42.0.0/16` added to trusted proxies, otherwise 400 on `dash`. HA's music_assistant entry still pointed at the old Docker IP `172.18.0.4:8095`; MA works from HA anyway. Pre-existing log noise: Midea unreachable, tarif_edf, `music-assistant==2.0.0b112` install, MA smart_fades model download. |
| 2026-10-21 | traefik → k3s Traefik on 80/443/22 (Phase 4.1) | `cluster` | `docker compose -f traefik.yaml rm -sf traefik`, push, copy `traefik-config.yaml` to `/var/lib/rancher/k3s/server/manifests/` | ~15 s outage of every site. Certs from cert-manager (valid, both domains), HTTP→HTTPS 301, :22 → gitea sshd. Real client IPs reach pods through ServiceLB (`externalTrafficPolicy: Local`; public and LAN IPs seen in authentik/vaultwarden logs); from the NAS itself the source is `10.42.0.1` (hairpin, so `lan-only` answers 403 there). `lan-only` Middleware (`cluster/base/lan-only.yaml`) on bao, argocd, adminer. Interim Prometheus target `10.0.0.2:8082` removed. Dropped: `traefik.fgdou.ovh` dashboard. Mailserver still reads `/data/traefik/acme.json` (no longer renewed, valid until 2027-01-01). Now unused: `/data/traefik/config.yaml`, `authentik/docker-bridge.yaml` (removed in Phase 4.7). |
| 2026-10-21 | mailserver (Phase 4.2) | `mail` | `docker compose -f mailserver.yml stop -t 60 mailserver` + `rm -f` | ~70 s outage of SMTP/IMAP, queue empty before the stop. Pin matched, relay secret compared first (same hash). Own cert-manager `Certificate` `mail-tls` (`fgdou.ovh`, `*.fgdou.ovh`) issued before the switch, `SSL_TYPE=manual` → `/data/traefik/acme.json` no longer used. Ports 25/143/465/587/993 via ServiceLB on `10.0.0.2` (`externalTrafficPolicy: Local`), same 4 accounts / 261 mail files, local delivery + DKIM OK, relay via Mailjet (sender-dependent map) and inbound from outside tested by the user. Consumers (mealie, grafana) unchanged: `mail.fgdou.ovh` → host IP. |
| 2026-10-21 | bind9, ddclient, restic (Phase 4.3) | `infra` | `docker compose -f restic.yml rm -sf restic`, same for `ddclient.yaml`, `bind9.yaml` | ~60 s outage of all DNS, then ~3 min more for external names. 2 pins matched (restic moves from lobaro 0.12.0 to `restic/restic` 0.19.1 on purpose), secret compared first (same hash). **Argo CD can't sync while bind9 is down** (the host and CoreDNS resolve through `10.0.0.2`, so github.com fails): applied `kubectl kustomize infra | kubectl apply -f -`, synced from Argo CD afterwards. Next time apply before stopping Docker. **DNSSEC broke on the fresh `emptyDir`**: the image's built-in root key (9.18.24) predates KSK-2024, which signs the root since 2026-10-11; Docker's container had learned it via RFC 5011. Fix in `/data/bind9/named.conf`: `dnssec-validation yes` + `trust-anchors` `initial-ds` 20326 and 38696 (checked against IANA `root-anchors.xml` and the live root DS). restic manifest fixed before enabling: back up `/data` (as lobaro did, host `/data` mounted at `/data/Backup`) to continue the weekly series; read-only `snapshots` + `check` job OK (5 snapshots, no errors), first real run Sunday 02:00 UTC. ddclient: one manual cycle updated `fgdou.ovh`. DNS on IPv6 (`[::]:53`, Docker) is gone: ServiceLB serves `10.0.0.2` only. Pre-existing: `plerin IN NS 1.1.1.1` is a fake delegation (A works, AAAA/MX SERVFAIL); bind can't forward one name out of its own zone (forward zone and real delegation tested), left as is by the user. |
| 2026-10-21 | minecraft (Phase 4.4) | `games` | `docker compose -f minecraft.yml rm -sf mc` | ~50 s outage. Pin matched, files uid 1000 as before, no secrets. The 10 s compose stop timeout killed the server during its `STOP_SERVER_ANNOUNCE_DELAY` (last autosave ~1 min before, server idle/paused; next time `stop -t 30`). Paper 26.3 build 207 → 211 on start (normal for `VERSION=26.3`). Port 25566 via ServiceLB on `10.0.0.2`; autopause/knockd works behind it (a TCP knock wakes the server). BlueMap `minecraft.fgdou.ovh` served by an IngressRoute (no bridge, Phase 4). spark `NumberFormatException: Infinite or NaN` after resume: pre-existing on Docker. Checked in-game by the user. |
| 2026-10-21 | meshcentral restart (Phase 4.5) | `apps-meshcentral` | — | `kubectl -n apps rollout restart deploy/meshcentral`. `certUrl` now loads the cert-manager cert: SHA384 `480c8394…23318170` (was Docker's `5b94c01c…cf76cab`). Before the restart MeshCentral had already reloaded it by itself after an agent reported the new hash (`Agent bad web cert hash … holding connection`). Startup takes ~1 min (npm module install, 502 meanwhile); 4 agents back online ~2 min after start (`power: 1` in `meshcentral-power.db`, no server log line for normal connects), checked in the UI by the user. |
| 2026-10-21 | watchtower, redis (Phase 4.6) | — | `docker compose -f watchtower.yml rm -sf watchtower`, `docker compose -f redis.yml rm -sf` | `docker ps -a` empty. Watchtower had nothing left to update (mariage/todoapp on k3s since 3.1); Docker redis had no consumers (no published ports, alone on `nas`). **Docker is kept enabled** by decision (not disabled as MIGRATION.md planned); images, volumes and compose files stay as the fallback. Still open: Image Updater sees new mariage digests but can't write back (`credentials for 'https://github.com/Fgdou/homelab-compose.git' are not configured`). |
| 2026-10-20 | shared redis | `databases-redis` | — (Docker's `redis.yml` stays for apps still on Docker) | Split out of `databases` (same 13 objects rendered). `redis.databases:6379` tested from the `apps` namespace (PING, SET/GET). Same image digest as Docker (8.6.1), no persistence. |

### Left over from the bootstrap

- ~~Disable the Argo CD local admin~~ — done 2026-10-20 (OIDC login verified): `admin.enabled: false`, `argocd-initial-admin-secret` deleted.
  Break-glass if authentik is down: the CLI still works with `argocd ... --core` (kubeconfig). For the UI: first `argocd app set platform-argocd --core --sync-policy none` (otherwise selfHeal reverts the patch), then `kubectl -n argocd patch cm argocd-cm -p '{"data":{"admin.enabled":"true"}}'`, set a password with `argocd account bcrypt --password <pw>` → `kubectl -n argocd patch secret argocd-secret -p '{"stringData":{"admin.password":"<bcrypt>","admin.passwordMtime":"'$(date +%FT%TZ)'"}}'`, log in, then `argocd app set platform-argocd --core --sync-policy automated --self-heal` to revert.
- Helm release metadata (`sh.helm.release.v1.*` Secrets in openbao, external-secrets, cert-manager, argocd) is now stale: Argo CD owns the resources. Never `helm upgrade/uninstall` these releases; delete the release Secrets (only metadata) to avoid confusion.
- `applicationSet.enabled: false` is ignored by chart 10.10.5 (the controller runs): find the right key.
- ~~Automated sync for the bootstrap Applications~~ — done 2026-10-20: all 9 (`cluster*`, `platform-*`) have `automated: { prune: false, selfHeal: true }`; every app stack too since 2026-10-21. A push to `main` is live within ~3 min; manual `kubectl` edits to their objects are reverted within seconds (selfHeal); nothing is ever deleted by a removal in git (`prune: false`). **Before any manual change** (break-glass, debugging): `argocd app set <app> --core --sync-policy none`, and re-enable with `argocd app set <app> --core --sync-policy automated --self-heal` — or simply push the change to git instead.
- Image Updater has no git write access yet (needed when `projects` is enabled).

## Enabling a stack (Phase 3)

1. Check the running version still matches the pin: `docker inspect <container> -f '{{.Image}}'` vs the digest in the manifest. Fix the pin if it changed.
2. Do the stack's migration notes below.
3. `docker compose -f <stack>.yml down`.
4. `git mv argocd/available/<stack>.yaml argocd/apps/`, commit, push.
5. In Argo CD: sync manually, test.
6. Add a Docker Traefik bridge router for each hostname of the stack in `/data/traefik/config.yaml` (see "Docker Traefik bridge"), and remove the stack's Traefik labels from its compose file.
7. Once it works, uncomment `automated` in the Application.

Rollback: `kubectl delete -k <stack>` (PVs are `Retain`, data stays), `git mv` the Application back to `available/`, `docker compose up -d`.

## Migration notes per stack

> **Service links trap** (found with actual): every Service in a namespace injects `<SERVICE>_PORT`, `<SERVICE>_HOST`… env vars into its pods. If an app reads a variable with that name (`ACTUAL_PORT`, `MEALIE_PORT`…), it breaks. Pods here use DNS names, never these vars → `enableServiceLinks: false` is set on every workload (62 pod templates, 2026-10-20). Charts: immich already sets it to false; the **authentik chart hard-codes `true`** (no value to change it) → check at the authentik migration that the injected `AUTHENTIK_SERVER_PORT`-style vars are ignored (authentik only maps `AUTHENTIK_X__Y`).

Things that the manifests cannot do by themselves, to do on migration day.

| Stack | Before enabling |
|---|---|
| all | Remove the stack's watchtower / Traefik-label dependency; the Docker Traefik bridge forwards its hostnames. |
| `databases` | Postgres: done 2026-10-21, alone; Docker consumers used `postgres-bridge.yml` until they moved (removed with warracker, 2026-10-21). Redis is **already on k3s** (`databases-redis`, 2026-10-20): each app switches to `redis.databases` when it migrates (transient data only), on its own db index (gramps 0-1, immich 2, dawarich 3-6; list in `databases/redis/redis.yaml`); remove Docker's `redis.yml` with its last consumer. |
| `nextcloud` | Done 2026-10-21 (`config.php` hosts changed, cron sidecar). Redis **db 7** since 2026-10-21 (`dbindex` in `config.php`; `REDIS_HOST` dropped from the Deployment, otherwise the image's `redis.config.php` replaces the whole `redis` array). Upgraded 32.0.3 → 33.0.5 on 2026-10-21: the container now starts through `/entrypoint.sh` (after the authentik wait), so a new image tag rsyncs the code and runs `occ upgrade` (one major version at a time). |
| `media` | Done 2026-10-21. Jellyfin LDAP plugin (`/data/Jellyfin/data/plugins/configurations/LDAP-Auth.xml`) points at `authentik-ldap.authentik` since the authentik migration (2026-10-21). VAAPI does not work yet: keep `HardwareAccelerationType=none` (optional, MIGRATION.md §11 Phase 5 step 2). |
| `authentik` | Done 2026-10-21. `authentik/docker-bridge.yaml` removed in Phase 4.7 (2026-10-21). |
| every app behind authentik | A hostname that has no authentik Proxy Provider yet (e.g. Argo CD, adminer) gets a **404** from forward-auth: create the provider (Forward auth, single application) and add it to the embedded outpost first. |
| `home` | Home Assistant and Music Assistant use `hostNetwork`: ports 8123, 8095, 8097, 21063, 58866-58867 are bound directly on the host. zigbee2mqtt keeps `mqtt://mosquitto:1883` (same namespace). |
| `monitoring` | Done 2026-10-21. No dashboard or alert used cadvisor or dockerd metrics → both dropped. `authentik` target up since the authentik migration (2026-10-21); `postgres-exporter` connects since 3.5 postgres (2026-10-21). Docker Traefik metrics scraped through `10.0.0.2:8082` (interim, certificate expiry alert). |
| `mail`, `infra` (bind9) | Only at the Phase 4 cutover: ports 25/143/465/587/993 and 53 are still owned by Docker. |
| `infra` (restic) | Stop the Docker restic before enabling: both would back up on Sunday. |
| `gitea` | SSH listens on 2222 until the Phase 4 cutover (Traefik `ssh` entrypoint). |
| `projects` | mariage / todoapp: Image Updater needs git write access (deploy key with write) to commit new digests. |
| `immich` | Chart is built for v2.6.3, images overridden to v3.3.3: check the server starts and finds the library at `/usr/src/app/upload`. |
| `dawarich` | `SECRET_KEY_BASE` comes from the running container (see OPENBAO-KEYS.md). |

## Phase 4 (cutover) changes in this repo

- ✅ 2026-10-21 `cluster/base/traefik-config.yaml`: `exposedPort` 80/443/22, `forwardedHeaders.trustedIPs` dropped, copied to `/var/lib/rancher/k3s/server/manifests/`; `lan-only` Middleware for bao, argocd, adminer.
- ✅ 2026-10-21 `monitoring/prometheus.yml`: interim `10.0.0.2:8082` Traefik target dropped.
- ✅ 2026-10-21 `authentik/docker-bridge.yaml` removed (Docker Traefik's forward-auth target, unused since 4.1); Service `authentik-server-docker` deleted, `10.0.0.2:9000` freed.
- ✅ 2026-10-21 `kube` merged (fast-forward) into `main`; every Application (`argocd/root.yaml`, `argocd/apps/*.yaml`) and the Image Updater write-back branch switched from `kube` to `main`.
- Enable `mail` and `infra`.
