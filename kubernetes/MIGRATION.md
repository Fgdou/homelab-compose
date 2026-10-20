# Docker Compose → Kubernetes migration

Status: **Phase 2 done** (2026-10-20): k3s runs next to Docker with OpenBao, External Secrets, cert-manager and Argo CD (+ Image Updater), managed by Argo CD from the `kube` branch; the Docker Traefik bridge is in place (bao, argocd). **Next: Phase 3.** Details and commands: [README.md](README.md).
Snapshot taken 2026-10-20 on the NAS (Ryzen 3 3200G, 4 threads, 32 GB RAM / 29 GiB usable).

TL;DR

- **k3s** with **embedded etcd** (`--cluster-init`), single server node for now, with its bundled Traefik, ServiceLB and local-path provisioner.
- GitOps with **Argo CD** (+ **Argo CD Image Updater** replacing watchtower), certificates with **cert-manager**, secrets with **External Secrets Operator + OpenBao**.
- Expect **+1.5 to +2.5 GB RAM** compared to today with this stack. On 32 GB this fits.
- The hard parts are not the pods. They are: **storage layout** (two disks with different value), **Traefik labels → IngressRoute**, **docker.sock consumers**, **host-bound services** (Home Assistant, zigbee USB, mail, DNS, Minecraft), and **OpenBao unsealing** after each reboot.

### Decisions (2026-10-20)

| Topic | Decision |
|---|---|
| Distribution | k3s, embedded etcd (`--cluster-init`) to be ready for HA |
| Namespaces | grouped by domain (§8), one per big stack |
| GitOps | Argo CD |
| Image auto-update (was watchtower) | Argo CD Image Updater |
| Certificates | cert-manager, Cloudflare DNS01, wildcard certs |
| Secrets | External Secrets Operator + OpenBao |
| Non-secret config | inline `env:`; ConfigMaps only for config files |
| Periodic containers | CronJob where the image allows it |
| Host ports | ServiceLB `LoadBalancer`; `hostNetwork` only for Home Assistant and Music Assistant |
| Cross-namespace DNS names | updated explicitly in each app's config (no `ExternalName` aliases) |
| NetworkPolicies | later, after the migration |
| Storage | static PVs on existing folders; `local-path` with two classes for new apps |
| Postgres data | stays on the NVMe (`/home/fgdou/postgres`) |
| LDAP outpost | manual Deployment with its token, as today |
| Gitea runner | act_runner + docker-in-docker sidecar |
| Manifest format | plain YAML + Kustomize for own/simple apps; official Helm charts for complex third-party software (immich, authentik, infra) — §8 |
| Jellyfin | mount the iGPU (`/dev/dri`) for hardware transcoding |
| Stopped stacks | not migrated |
| Image versions | compose files left as they are (`:latest` stays); every image **pinned** in the k8s manifests |

---

## 1. Current state (inventory)

- 42 compose files, ~85 services defined, **70 containers running**.
- Not running right now, **not migrated**: `audiobookshelf`, `endurain`, `frigate`, `homarr`, `ihatemoney`, `jdownloader`, `matrix` + `element`, `pca`, `wekan`. Their compose files and `/data` folders stay as they are.
- One shared external network `nas`, plus private per-stack networks (`authentik`, `immich`, `dawarich`, `monitoring`, `torrent`, `gitea`, `ciq`, `pca`, `wekan`, `endurain`, `guac`, `gramps-internal`, `warracker`).
- Shared backends on `nas`: `postgres` (authentik, nextcloud, guacamole, warracker, postgres_exporter), `redis` (dawarich, gramps, immich, nextcloud).
- Reverse proxy: Traefik v3.6 with the docker provider (labels), Let's Encrypt wildcard certs via Cloudflare DNS challenge, `authentik` forward-auth middleware.
- Secrets: a single `.env` (gitignored), injected with `${VAR}` interpolation and `env_file`.

### Things to fix before (or during) the migration

These exist today, independent of Kubernetes, and are easier to fix while moving:

| Issue | Why it matters | Decision |
|---|---|---|
| `postgres` data is in `/home/fgdou/postgres` (NVMe root disk) | Not on the RAID1 and not covered by restic. Only the daily dumps in `/data/postgres_backups` are protected. | **Keep it on the NVMe** (faster disk). Static `local` PV on `/home/fgdou/postgres`. Accepted risk: if the NVMe dies, restore from the last daily dump (up to 24 h of data lost). Dump frequency stays daily. |
| Named docker volumes: `todoappdata`, `model-cache` (immich), `cache` (bind9) | Live in `/var/lib/docker`, not backed up. `todoappdata` holds app data; the others are caches. | **All three → `emptyDir`.** todoapp data is disposable and is wiped on every pod restart or redeploy. Immich ML re-downloads its models on each pod restart (slower start). |
| Hardcoded passwords (`password`, `user`) in `ciq`, `pca`, `immich`, `endurain`, `dawarich`; AWS access key ID in `restic`/`monitoring` | Plain text in git. | **Move them into OpenBao with the same values** while converting (no rotation; they are internal-only DB credentials). |
| Unused `.env` keys (`VOUCHERVAULT_*`, `CURSE_API`, `LITELLM_MASTER_KEY`, `LDAP_SEED`, `LDAP_JWT`, `CIQ_AUTHENTIK_*`) | Noise when splitting `.env` into per-namespace Secrets. | **Done** (2026-10-20): deleted from `.env`. |
| `openwebui`, `audiobookshelf/config`, `jellyseerr`, arr configs (`Radarr`, `Sonarr`, `prowlarr`, `qbittorrent`) are on `/films` | Single disk, not backed up; the arr/jellyseerr configs take time to recreate. | **Leave them on `/films`.** Losing them with the disk is accepted. |

---

## 2. Concept mapping

| Docker Compose | Kubernetes |
|---|---|
| one `*.yml` file / stack | a **namespace** grouped by domain (§8), one Kustomize folder per namespace, one Argo CD Application per folder |
| `service` | **Deployment** (stateless) or **StatefulSet** (databases), 1 replica |
| periodic container (`restic`, `pg_backups`, `soularr`) | **CronJob** (one-shot image); Deployment only if the image can't run one-shot |
| one-per-host container (`node-exporter`) | **DaemonSet** |
| container name / hostname on the network | **Service** (ClusterIP) → DNS `name.namespace.svc.cluster.local` |
| `ports:` on the host | **Service type LoadBalancer** (k3s ServiceLB binds the host port); `hostNetwork` only for Home Assistant and Music Assistant |
| Traefik labels | **IngressRoute** / **IngressRouteTCP** / **Middleware** CRDs |
| bind mount `/data/...` / `/films/...` | **PersistentVolume + PersistentVolumeClaim** |
| named volume used as cache, `tmpfs`, `shm_size` | **emptyDir** (`medium: Memory` for tmpfs and `/dev/shm`) |
| `environment:` (non-secret) | inline `env:` in the Deployment; **ConfigMap** only for config files (`prometheus.yml`, `mosquitto.conf`, …) |
| `.env` / `env_file` / `${VAR}` | value in **OpenBao** → **ExternalSecret** → Secret per namespace (`envFrom` / `secretKeyRef`) |
| `healthcheck` | **livenessProbe / readinessProbe / startupProbe** |
| `depends_on` | no equivalent — pods restart until the dependency is up; use an `initContainer` "wait-for" when an app crashes badly |
| `restart: always / unless-stopped` | default behaviour of Deployments |
| `deploy.resources.limits` | `resources.requests` / `resources.limits` |
| `devices`, `privileged`, `cap_add` | `securityContext` + `hostPath` of type `CharDevice` |
| `dns:` | `dnsConfig` / `dnsPolicy` |
| `extra_hosts` | `hostAliases` |
| YAML anchors (`gramps`) | Kustomize base + patch |
| watchtower | **Argo CD Image Updater** (see §7) |

---

## 3. Networks

Kubernetes has **one flat network**: every pod can reach every Service of every namespace. There is no "attach to network X".

- **`nas` network** → disappears. Traefik reaches any Service directly.
- **Private networks** (`immich`, `dawarich`, `ciq`, …) → **NetworkPolicies, added after the migration** (k3s ships a NetworkPolicy controller with flannel). The flat network during the migration is about as isolated as today's shared `nas` network. Target baseline per namespace:
  - default deny ingress,
  - allow from the same namespace,
  - allow from `kube-system` (Traefik) to the web pods,
  - allow from `monitoring` (Prometheus scraping),
  - allow namespaces using shared postgres/redis → `databases` namespace,
  - allow `external-secrets` → `openbao`.
- **DNS names change.** Cross-namespace names become `<service>.<namespace>`, **set explicitly in each app's config** (no `ExternalName` aliases):
  - `postgres` → `postgres.databases`, `redis` → `redis.databases`, `authentik_server` → `authentik-server.authentik`, `authentik_ldap` → `authentik-ldap.authentik` (jellyfin, port 6636), `jellyfin` (used by `jellyfin_exporter`), `lidarr` (used by `musiseerr`), `mosquitto` (used by zigbee2mqtt/HA config).
  - Underscores are not allowed in Service names (`immich_database`, `dawarich_db`, `authentik_server`, `authentik_ldap`) → rename to `-` and update the env vars.
- **IP ranges change.** k3s pods are in `10.42.0.0/16`, Services in `10.43.0.0/16`. Update:
  - `trilium`: `TRILIUM_NETWORK_TRUSTEDREVERSEPROXY=172.18.0.0/16` → `10.42.0.0/16`
  - `nextcloud`: `TRUSTED_PROXIES` already contains `10.0.0.0/8` (ok).
  - `bind9` fixed IP `172.18.0.254` → no fixed pod IPs in k8s; expose through a LoadBalancer Service on port 53 and point clients at the host IP.
  - `prometheus` `host.docker.internal` → node IP or a Service.

---

## 4. Storage (PV / PVC)

### Two storage classes, matching the two disks

| StorageClass | Backed by | Reclaim policy | Used for |
|---|---|---|---|
| `data` | `/data` (RAID1 + restic → S3) | **Retain** | databases, app configs, anything irreplaceable |
| `films` | `/films` (big single disk, re-downloadable) | Retain | media libraries, downloads, app configs you accept to lose |

Exception: postgres data stays on the NVMe (`/home/fgdou/postgres`, see §1).

### Existing apps: static PVs on the existing folders

Do **not** let a dynamic provisioner create random folders (`pvc-<uuid>`) for existing data: it breaks the readable `/data/<app>` layout that restic and you rely on.
Create **static `local` PVs** pointing at the existing directories (no data copy needed), each PVC bound by `volumeName`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vaultwarden-data
spec:
  storageClassName: data
  capacity: { storage: 1Gi }          # informative for local volumes
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  local:
    path: /data/VaultWarden
  nodeAffinity:                        # pins the pod to the NAS node
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - { key: kubernetes.io/hostname, operator: In, values: [nas] }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vaultwarden-data
  namespace: apps
spec:
  storageClassName: data
  volumeName: vaultwarden-data
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
```

### New apps: `local-path`, two classes

Volumes for apps added after the migration use the k3s `local-path` provisioner, configured with two classes: `data-dynamic` → `/data/k8s`, `films-dynamic` → `/films/k8s`, `reclaimPolicy: Retain`, and a `pathPattern` of `{{ .PVC.Namespace }}/{{ .PVC.Name }}/` (trailing `/` required since v0.0.37) so folders stay readable (`/data/k8s/<namespace>/<pvc>`).

### Shared media folders

`/films/Films`, `/films/music`, `/films/Films/Download`, `/films/slskd/downloads` are mounted by many pods (jellyfin, radarr, sonarr, qbittorrent, lidarr, navidrome, slskd, soularr). With a single node, one PV per shared folder mounted by several pods works (`ReadWriteOnce` = one *node*, not one pod). Use `subPath` to mount sub-folders (`films`, `series`).
When a second node arrives, these must become NFS (exported from the NAS) or the media pods stay pinned to the NAS node.

### Per-app volume plan

| App | `data` class | `films` class | ephemeral (`emptyDir`) |
|---|---|---|---|
| postgres | `/data/postgres_backups` (data itself stays on the NVMe: local PV on `/home/fgdou/postgres`) | | |
| authentik | `/data/authentik/{media,custom-templates,certs}` | | |
| immich | `/data/immich/core`, `/data/immich/db` | | `model-cache` |
| dawarich | `/data/dawarich/{db_data,shared,public,watched,storage}` | | `/dev/shm` 1Gi (Memory) |
| nextcloud | `/data/nextcloud/code` | | |
| gitea | `/data/gitea` | | runner docker storage (DinD) |
| mailserver | `/data/mail/{mail-data,mail-state,mail-logs,config}` | | |
| homeassistant | `/data/Homeassistant/{core,media,zigbee2mqtt,mosquitto,musicassistant}` | | |
| monitoring | `/data/monitoring/{prometheus,grafana,ntfy,json_exporter}` | | |
| gramps | `/data/gramps/*` (8 folders → 1 PV + subPaths, `gramps_tmp` stays mounted on `/tmp` as today) | | |
| ciq | `/data/ciq` | | |
| openbao | `/data/openbao` (integrated storage) | | |
| small apps (actual, vaultwarden, trilium, mealie, lubelogger, meshcentral, warracker, guacamole, minecraft, sr, lidarr, soularr, navidrome, jellyfin config, bind9, ddclient) | `/data/<app>` | | |
| arr suite + jellyseerr + qbittorrent + slskd | | `/films/<app>` configs | |
| media libraries | | `/films/Films`, `/films/music` | |
| openwebui | | `/films/openwebui` | |
| firefox | | | `/dev/shm` 1Gi |
| bind9 cache | | | `/var/cache/bind` |
| todoapp | | | data volume (was `todoappdata`) |
| restic | `/data` read-only (`hostPath`) | | |

Host files currently bind-mounted (`/etc/localtime`, `/etc/timezone`, `/run/dbus`, `/run/udev`, `/proc`, `/sys`, `/`) → `hostPath` volumes, or simply `TZ=Europe/Paris` for the timezone.

### Backups

Nothing changes for restic: it still backs up `/data` from the host. Postgres data stays outside restic (on the NVMe); it is only protected by the dumps in `/data/postgres_backups`.

Add to the backups:

- `/data/openbao` (OpenBao storage). The **unseal keys and root token** must be kept **outside the cluster** (e.g. in Vaultwarden); without them the backup is useless.
- the k3s **etcd snapshots**: k3s takes them automatically (every 12 h, 5 kept, in `/var/lib/rancher/k3s/server/db/snapshots`) → include that folder, plus the server token `/var/lib/rancher/k3s/server/token`. Do **not** back up the rest of `/var/lib/rancher` blindly.
- manifests are in git (Argo CD reads them from there), nothing else to back up for them.

---

## 5. Reverse proxy (Traefik)

k3s installs Traefik as a Helm chart in `kube-system`. Reuse it and configure it with a `HelmChartConfig` instead of running a second one.

### Entrypoints and global options

Same as today's command line, expressed as Helm values:

- `web` :80 → redirect to `websecure`
- `websecure` :443, `readTimeout/writeTimeout/idleTimeout=600s`, `allowEncodedHash`, `allowEncodedSlash`
- `ssh` :22 (TCP, for Gitea) — host sshd must stay on another port as today
- `metrics` :8082 (Prometheus)
- `serversTransport.insecureSkipVerify=true` (MeshCentral serves HTTPS on 443)
- `providers.kubernetesCRD.allowCrossNamespace=true` (to use the authentik middleware from every namespace)
- `service.spec.externalTrafficPolicy: Local` to keep real client IPs (needed by authentik, vaultwarden, mailserver logs, fail2ban-like features)

### Certificates: cert-manager

- `ClusterIssuer` with Cloudflare DNS01 (API token in OpenBao → ExternalSecret in `cert-manager`).
- Two wildcard `Certificate`s (`*.fgdou.ovh`, `*.ciq-panier.fr`) stored as Secrets, used as Traefik's default `TLSStore`.
- The **mailserver** gets its certificate from the same Secret (copied to the `mail` namespace, e.g. with a second `Certificate` for `mail.fgdou.ovh`) instead of reading Traefik's `acme.json` (today `/data/traefik/acme.json` is mounted into the mail container).
- Cost: ~100–150 MB RAM.

### Labels → CRDs

Every app currently uses the same 4 labels. Example (`actual`):

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: actual
  namespace: apps
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`actual.fgdou.ovh`)
      kind: Rule
      services:
        - name: actual
          port: 5006
      # middlewares:                      # for apps that had authentik@docker
      #   - name: authentik
      #     namespace: authentik
```

- `authentik@docker` forward-auth → one `Middleware` in the `authentik` namespace, `forwardAuth.address: http://authentik-server.authentik:9000/outpost.goauthentik.io/auth/traefik`, same `authResponseHeaders`. Apps using it today: firefox, lubelogger, navidrome, prometheus, radarr, sonarr, prowlarr, qbittorrent, lidarr, slskd, musiseerr, trilium, zigbee2mqtt, traefik dashboard. Add adminer (was exposed on host port 8080 without auth) and the Argo CD UI (or use its own OIDC login with authentik). The OpenBao UI uses OpenBao's own OIDC auth method with authentik instead (done 2026-10-20).
- **Navidrome** two routers (path-based bypass of auth for `/rest` and `/share`) → two routes in the same IngressRoute, only one with the middleware.
- **Gitea SSH** `HostSNI(*)` on `ssh` → `IngressRouteTCP`.
- **Traefik dashboard** (`api@internal`) → IngressRoute to `api@internal` with the authentik middleware; drop `api.insecure`.
- The empty file provider `/data/traefik/config.yaml` is useful during the transition (see §11).

### Non-HTTP ports (no Traefik)

| Service | Ports | Kubernetes exposure |
|---|---|---|
| mailserver | 25, 143, 465, 587, 993 | `LoadBalancer` (ServiceLB), `externalTrafficPolicy: Local` |
| bind9 | 53/tcp, 53/udp | `LoadBalancer` |
| minecraft | 25566 → 25565 | `LoadBalancer` port 25566 |
| slskd | 50300 | `LoadBalancer` |
| homeassistant (Roborock 58866/udp, 58867, HomeKit 21063, mDNS) | | **`hostNetwork: true`** (discovery/mDNS needs it) |
| musicassistant | 8095, 8097 + discovery | **`hostNetwork: true`** |

With `hostNetwork`, set `dnsPolicy: ClusterFirstWithHostNet` so the pod still resolves `mosquitto.home`, etc.

---

## 6. Environment variables and secrets

### External Secrets Operator + OpenBao

- **OpenBao** (open-source fork of HashiCorp Vault) runs in the `openbao` namespace, single replica, integrated storage on `/data/openbao`. It is the single source of truth for secrets; `.env` is imported into it once.
- **External Secrets Operator** (`external-secrets` namespace) authenticates to OpenBao with the Kubernetes auth method through one `ClusterSecretStore`, and syncs values into regular Secrets.
- Each namespace has one **`ExternalSecret`** (committed in git — it only contains key paths, no values) producing the Secret the pods use with `envFrom` / `secretKeyRef`. Layout in OpenBao: `kv/<namespace>/<app>`; shared values (`SMTP_PASSWORD`, `POSTGRES_ADMIN_PASSWORD`) are stored once (`kv/shared/...`) and referenced by every ExternalSecret that needs them.
- **Unsealing**: OpenBao starts sealed after every pod or node restart. Until it is unsealed, ESO cannot refresh Secrets (existing Secrets keep working, new ones and changes are blocked). Either unseal manually after each reboot (`bao operator unseal`), or set up auto-unseal. Keep the unseal keys and root token outside the cluster (Vaultwarden).
- **Bootstrap order** (chicken-and-egg): OpenBao and ESO must not depend on secrets served by OpenBao. Install them first, unseal, load the secrets, then everything else. The Argo CD repository credentials are created by hand once (or stored in OpenBao after bootstrap).

### Values

- Compose defaults like `${POSTGRES_USER:-postgres}` / `${APP_MEMORY_LIMIT:-4G}` must be **resolved** into literal values (Kubernetes does no interpolation; `$(VAR)` only references other env vars of the same container).
- `env_file: .env` (authentik server/worker, immich ML) injects *all* keys today → use `envFrom` on a dedicated Secret with only the needed keys.
- Hardcoded passwords from the compose files go into OpenBao with the same values.
- Never commit plain `Secret` manifests.
- Non-secret config (OIDC client IDs, URLs) stays inline in the Deployment `env:`; config files go into ConfigMaps.

---

## 7. Special cases

| Service | Problem | Solution |
|---|---|---|
| traefik | docker.sock for the docker provider | replaced by k3s Traefik + kubernetesCRD provider |
| authentik | docker.sock + `user: root` on the worker for the Docker outpost integration (no longer used) | **Official Helm chart** (Argo CD Application with a values file), without docker.sock |
| authentik LDAP outpost | used by jellyfin on 6636 | **Manual Deployment** (`ghcr.io/goauthentik/ldap`) with its token from OpenBao, as today; Service `authentik-ldap` in `authentik`. Bump its image tag together with the authentik chart |
| gitea_runner | docker.sock to run CI jobs | act_runner + **docker-in-docker sidecar** (`docker:dind`, privileged), `DOCKER_HOST=tcp://localhost:2376`, emptyDir for the DinD storage. Existing workflows work unchanged |
| watchtower | auto-update `mariage`, `todoapp` every minute | **Argo CD Image Updater**: watches the registry for new images of these two apps and writes the new tag back to git (`kustomization.yaml` `images:`), Argo CD then syncs it. Needs registry read credentials and git write credentials. Watchtower is removed |
| cadvisor | container metrics | **removed**: the kubelet embeds cAdvisor (`/metrics/cadvisor`). Saves ~220 MB |
| node-exporter | host mounts | DaemonSet with `hostPID`, `hostNetwork`, hostPath `/proc` `/sys` `/` |
| prometheus | static targets on docker names, config file inside the TSDB folder | rewrite the scrape config (see **Prometheus scrape config** below); add `kubernetes_sd_configs` + scrape kubelet/cAdvisor; RBAC to read the API. Expect more series (k8s metrics) → a bit more RAM |
| zigbee2mqtt | `/dev/ttyACM0` | hostPath `type: CharDevice` + `privileged: true` (or a device plugin), pinned to the NAS node |
| homeassistant | `privileged`, `/run/dbus`, mDNS/HomeKit | `hostNetwork`, privileged, hostPath `/run/dbus` |
| musicassistant | `SYS_ADMIN`, `DAC_READ_SEARCH`, `apparmor:unconfined` | `securityContext.capabilities.add`, `appArmorProfile: Unconfined`, `hostNetwork` |
| jellyfin | no GPU today (software transcoding) | **mount `/dev/dri/renderD128`** (Vega iGPU) as hostPath `CharDevice`, add the host's `render` group GID to `supplementalGroups`, enable VAAPI in Jellyfin → big CPU savings on this 4-thread CPU. Pinned to the NAS node |
| dawarich | `shm_size: 1G`, cpu 0.5 / mem 4G limit, `stdin_open`/`tty` | emptyDir Memory, `resources.limits`, `stdin: true`/`tty: true` |
| minecraft | `MAX_MEMORY=4G`, autopause, tty | memory limit ≥ 5Gi (JVM overhead) else OOMKill; `stdin/tty: true` |
| mailserver | `hostname: mail.fgdou.ovh`, `dns: 8.8.8.8`, uses Traefik's acme.json | `hostname`+`subdomain` or `setHostnameAsFQDN`, `dnsConfig`, cert Secret from cert-manager; `terminationGracePeriodSeconds: 60` |
| restic | `privileged`, internal cron | **CronJob** with the plain `restic` image (backup + forget/prune), `/data` mounted read-only |
| pg_backups | internal cron | **CronJob** running `pg_dumpall` into `/data/postgres_backups` |
| soularr | internal loop (`SCRIPT_INTERVAL`) | **Deployment** as today: the image has no one-shot mode |
| nextcloud | custom command waiting for authentik | keep as is, or move to an `initContainer` |
| gramps | YAML anchor shared by web + celery | two Deployments in one file (same env and volumes, celery has its own command) |
| immich | official compose | **official Helm chart** (immich-charts) as an Argo CD Application; model cache on emptyDir |
| `:latest` images (arr suite, wordpress, flaresolverr, adminer…) | on k8s, any pod restart (reboot, eviction) can silently pull a newer version, and git can't roll it back | **pin in the k8s manifests** (see below); the compose files are not changed |

### Prometheus scrape config

Today's `/data/monitoring/prometheus/prometheus.yml` won't crash Prometheus on k8s (unresolvable targets just show `DOWN`), but almost every job stops collecting:

| Job | Target today | On k8s |
|---|---|---|
| prometheus | `localhost:9090` | unchanged |
| node | `node-exporter:9100` | node-exporter is a hostNetwork DaemonSet → node IP, or `kubernetes_sd_configs` role `node` |
| authentik | `authentik_server:9300` | `authentik-server.authentik:9300` (check the Service name and that the Helm chart exposes the metrics port) |
| docker | `host.docker.internal:9323` | **remove** (no `host.docker.internal` in k8s, dockerd disabled at cutover) |
| traefik | `traefik:8082` | Traefik is in `kube-system` and the k3s chart doesn't expose 8082 on its Service → add a metrics Service in the `HelmChartConfig` |
| cadvisor | `cadvisor:8080` | **replace** with the kubelet's `/metrics/cadvisor` (HTTPS, ServiceAccount token, RBAC on `nodes/metrics`) |
| s3 | `s3_exporter:9340` (http_sd) | `s3-exporter:9340` |
| blackbox | `blackbox:9115` + public URLs | unchanged (`dash.fgdou.ovh` is Home Assistant, kept) |
| json | `json_exporter:7979` | `json-exporter:7979` |
| jellyfin_exporter | `jellyfin_exporter:9594` | `jellyfin-exporter:9594` |
| postgres-exporter | `postgres_exporter:9187` | `postgres-exporter:9187` (stays in `monitoring`, connects to `postgres.databases`) |

Also:

- **Config location**: the config sits inside the TSDB folder (`/data/monitoring/prometheus/prometheus.yml`). Move it to a ConfigMap mounted at `/etc/prometheus/prometheus.yml` and change `--config.file`; the PV keeps only the TSDB.
- **Grafana dashboards**: standalone cadvisor labels containers with `name="compose-xxx-1"`; the kubelet's cAdvisor uses `namespace` / `pod` / `container`. Rewrite the queries using `name=`, and those filtering on `job="cadvisor"` / `job="docker"`.
- **During Phase 3**: an exporter moved to k8s while Prometheus is still on Docker shows `DOWN`. Migrate the exporters together with Prometheus (Phase 3 step 4), or accept gaps in the graphs.

### Image versions

Goal: be able to restore a service from backup with the image version that wrote its data. A large version gap between data and image is what breaks startups (failed migrations, especially immich and authentik).

- **Docker compose: not changed.** `:latest` tags stay as they are until each stack is migrated.
- **Kubernetes manifests: every image is pinned** when the manifest is written, to the version running on Docker at that moment (`docker inspect` the running container), so the migration itself changes no app version. Pinning by digest (`image: radarr:5.14@sha256:…`) also protects against re-pushed tags.
- **Updates in small steps:** an automated tool (Renovate, or Argo CD Image Updater with semver constraints — to decide) proposes each new version as a git commit. Pinned tags never drift far behind, and every upgrade is dated in git.
- **Restore:** take the backup date, check out the matching git commit, and the images match the data.

---

## 8. Namespaces

| Namespace | Content |
|---|---|
| `kube-system` | Traefik (bundled), CoreDNS, ServiceLB, local-path, metrics-server |
| `argocd` | Argo CD, Argo CD Image Updater |
| `cert-manager` | cert-manager, ClusterIssuer |
| `openbao` | OpenBao |
| `external-secrets` | External Secrets Operator, ClusterSecretStore |
| `databases` | postgres, adminer, pg-backups, redis |
| `authentik` | server, worker (Helm chart), LDAP outpost, forward-auth Middleware |
| `monitoring` | prometheus, grafana, ntfy, node-exporter, blackbox, json/jellyfin/postgres/s3 exporters |
| `media` | jellyfin, navidrome, radarr, sonarr, lidarr, prowlarr, flaresolverr, qbittorrent, jellyseerr, slskd, soularr, musiseerr |
| `home` | homeassistant, zigbee2mqtt, mosquitto, musicassistant |
| `immich`, `dawarich`, `gitea`, `mail`, `nextcloud` | one per big stack |
| `apps` | actual, openwebui, vaultwarden, trilium, mealie, lubelogger, speedtest, firefox, meshcentral, warracker, gramps, guacamole |
| `projects` | sr, mariage, todoapp |
| `games` | minecraft |
| `infra` | bind9, ddclient, restic |
| `ciq` | external website (WordPress + MySQL + its ddclient) |

Repository layout:

```
kubernetes/
├── MIGRATION.md
├── argocd/             # root app-of-apps, Image Updater config
│   └── apps/           # one Application file per ENABLED stack only (the gate, see below)
├── cluster/            # k3s config, HelmChartConfig traefik, cert-manager issuers, storage classes, ClusterSecretStore
├── databases/          # kustomization.yaml, postgres.yaml, redis.yaml, pv.yaml, externalsecret.yaml
├── authentik/          # Helm values + LDAP outpost Deployment
├── media/
└── ...                 # one folder per namespace
```

### Helm or plain YAML

| Kind of app | Format | Why |
|---|---|---|
| Your own apps, single-container services (actual, vaultwarden, arr suite, gramps, mariage, …) | **plain YAML + Kustomize** | What's in git is exactly what runs: readable Argo CD diffs, easy debugging. Kustomize covers the needs: base + patches (gramps web/celery), namespace, `images:` overrides (edited by the update tool), `configMapGenerator` for config files |
| Complex third-party software with a maintained official chart (immich, authentik, Argo CD, cert-manager, External Secrets, OpenBao) | **official Helm chart + a small `values.yaml`** | The chart brings CRDs, RBAC, webhooks and upgrade logic you don't want to maintain; an upgrade is a chart-version bump in git |

Rule: upstream maintains a chart and the software has many moving parts → Helm. A single container you configure yourself → plain YAML. Don't write your own Helm charts (not even one generic "app" chart): every app ends up needing a special case and the chart turns into a pile of `if`s. Argo CD handles both natively (an Application points at a Kustomize folder or at a chart + values).

### Argo CD does not deploy everything

All stack folders are written before the migration starts (§11 Phase 1), but **Argo CD must only deploy the stacks already migrated**. Otherwise pods would start next to the Docker containers on the same `/data` folders (two databases on the same files = corruption).

- The root app-of-apps only reads `argocd/apps/`. A stack folder without an Application file in `argocd/apps/` is ignored by Argo CD.
- **Enabling a stack** = stopping it on Docker, then committing its Application file into `argocd/apps/`.
- A new Application starts with **manual sync** (no `automated:`); turn on automated sync + `selfHeal` only once the stack is verified. Keep `prune` off during the migration.
- **Rollback** = `docker compose up -d` after removing the Application file (with `resources-finalizer` absent, deleting the Application leaves the PVs and data untouched; `Retain` on every PV is the second safety).

Bootstrap only (`cluster/`, OpenBao, ESO, cert-manager, Argo CD itself) is applied by hand with `kubectl apply -k` / `helm install`, then their Applications are added to `argocd/apps/` so Argo CD takes over their management.

---

## 9. RAM impact

### Measured today

- `docker stats` on 2026-10-20: **17.3 GiB** for the 70 running containers, + ~220 MB for `dockerd`/`containerd`. Your ~20 GB figure includes the rest of the host (kernel, other processes).
- Biggest consumers: minecraft 1.8 G, grampsweb 1.3 G, homeassistant 1.1 G, postgres 850 M, authentik server 790 M, dawarich db 745 M, openwebui 715 M, immich 705 M, ciq mysql 625 M, firefox 605 M.
- The 9 stopped stacks are not migrated, so they don't count.

### Workloads: same RAM

The apps use the same memory in a pod as in a container — same image, same process. Kubernetes adds nothing per pod except a tiny `pause` container (~0.5–1 MB each, ~70 MB total).

### Overhead of the cluster itself

| Component | k3s (single node, chosen) | kubeadm "full" k8s |
|---|---|---|
| API server + controller-manager + scheduler + kubelet + kube-proxy | 500–800 MB (one process) | 600–1000 MB |
| datastore | embedded etcd: 100–200 MB | etcd: 150–300 MB |
| CNI | flannel (in k3s process) | Calico 150–250 MB / Cilium 300–500 MB |
| CoreDNS | 30–70 MB | 2 replicas: 60–140 MB |
| metrics-server, local-path, ServiceLB pods | ~100 MB | add-ons to install |
| **Total cluster overhead** | **≈ 0.8–1.3 GB** | **≈ 1.2–2.2 GB** |

### Chosen add-ons

| Add-on | RAM |
|---|---|
| Argo CD | 0.5–1 GB |
| Argo CD Image Updater | ~50 MB |
| cert-manager | 100–150 MB |
| External Secrets Operator | 50–100 MB |
| OpenBao | 100–150 MB |
| **Total** | **≈ 0.8–1.45 GB** |

### Freed

| Removed | Saved |
|---|---|
| cadvisor (kubelet has it) | ~220 MB |
| watchtower | ~35 MB |
| docker daemon (once everything is migrated; k3s uses its own containerd) | ~150 MB |
| **Total** | **≈ 0.4 GB** |

### Not chosen (for reference)

| Add-on | RAM |
|---|---|
| kube-state-metrics + extra Prometheus series | 150–400 MB |
| kube-prometheus-stack instead of your own prometheus/grafana | +0.5–1 GB vs today |
| Longhorn (replicated storage) | 1–1.5 GB → **not worth it on one node** |

### Result

| Scenario | Containers | Estimate | vs today |
|---|---|---|---|
| Today (Docker) | 17.3 GiB | ~20 GB host | — |
| **k3s + etcd + Argo CD + Image Updater + cert-manager + ESO + OpenBao (chosen)** | 17.3 GiB | **~21.5–22.5 GB** | **+1.5 to +2.5 GB** |
| kubeadm k8s + Calico + same add-ons | 17.3 GiB | ~22.5–23.5 GB | +2.5 to +3.5 GB |

On 32 GB this leaves **~9.5 GB** free, used by Linux as page cache (13 GiB of cache today — this is what keeps Jellyfin/Immich/Postgres fast, so don't fill it up with limits "just because").

During the migration Docker and k3s run side by side, but each app only runs once (stop the compose service before starting the pod), so the peak is today + ~2.5 GB.

### Requests / limits advice

- Set **memory requests** ≈ current usage (from the table above) so the scheduler knows the real picture once there are several nodes.
- Set **memory limits** only on apps known to leak or spike (dawarich 4G, mealie 1G, minecraft 5G, immich ML, openwebui, firefox). A limit too close to usage = OOMKill loop.
- Avoid CPU limits (throttling on a 4-thread CPU hurts more than it helps); use CPU requests only.
- Argo CD's `application-controller` and `repo-server` are the heavy parts; give them memory limits so a big sync can't starve the apps.
- k3s kubelet: reserve memory for the system (`--kube-reserved=memory=512Mi --system-reserved=memory=1Gi`) and keep eviction thresholds sane, otherwise the kubelet can evict pods under page-cache pressure.

---

## 10. k3s or k8s?

**Decision: k3s, with embedded etcd (`--cluster-init`).**

| | k3s | kubeadm (vanilla k8s) |
|---|---|---|
| Install | one binary, `curl -sfL https://get.k3s.io \| sh -` | kubeadm + containerd + CNI + add-ons |
| RAM overhead | ~0.8–1.3 GB (with etcd) | ~1.2–2.2 GB |
| Bundled | Traefik, ServiceLB, local-path, metrics-server, flannel, NetworkPolicy controller, Helm controller | nothing |
| Conformance | CNCF certified — **same API, same manifests** | reference |
| Upgrades | replace binary (or system-upgrade-controller) | `kubeadm upgrade` per minor version, more steps |
| Multi-node | `k3s agent` with a join token; HA with 3 servers + embedded etcd | same capabilities, more setup |
| Real-world fit | homelab / edge / small clusters | big clusters, very specific needs |

The 4-thread Ryzen 3 is the real constraint: a vanilla control plane burns noticeably more CPU in the background (etcd, separate components) than k3s.

### Planning for more servers later

- Manifests written for k3s run on any Kubernetes, so the choice is **not a lock-in**.
- The server starts with **`--cluster-init`** (embedded etcd), so going HA later is just joining 2 more servers (`k3s server --server https://nas:6443 --token …`). etcd needs 3 servers for quorum: 2 servers is *less* available than 1.
- Adding a **worker** node: `k3s agent --server https://nas:6443 --token …` — trivial.
- The real multi-node problem is **storage, not the distribution**:
  - `/data` (RAID1) and `/films` only exist on the NAS → pods using them stay pinned there via the PV `nodeAffinity`. That's fine: the NAS stays the "storage node", other nodes run stateless/CPU-heavy pods (immich ML, minecraft, CI runners).
  - To let pods move freely: export `/data` and `/films` over **NFS** from the NAS (nfs-subdir-external-provisioner / csi-driver-nfs). Avoid NFS for databases (postgres, mysql, mongo, sqlite apps) — keep them pinned on local disk.
  - Longhorn/Ceph only make sense with 3+ nodes with their own disks.
- Hardware-bound pods (zigbee USB, Home Assistant, Jellyfin with iGPU) → `nodeSelector` on the NAS.
- Ingress on several nodes: ServiceLB runs on every node; point DNS/router at one, or add kube-vip / MetalLB for a floating IP.

Alternatives considered: **k0s** (similar to k3s, less homelab ecosystem), **MicroK8s** (snap-based, heavier), **Talos** (excellent but needs its own OS — not suitable for a NAS that also runs mdadm RAID and host services).

---

## 11. Migration plan

Docker and k3s can coexist (k3s uses its own containerd). The only conflicts are host ports (80, 443, 22, 53, 25…).

**Phase 0 — prepare (on Docker)** — ✅ done 2026-10-20
1. Take a full restic snapshot + postgres dump.

**Phase 1 — write all the manifests (no cluster, Docker untouched)** — ✅ done 2026-10-20, see [README.md](README.md)
1. Write every folder of `kubernetes/`: `cluster/`, the infra (OpenBao, ESO, cert-manager, Argo CD + Image Updater values), and every stack (Kustomize or Helm values, PVs on the existing paths, ExternalSecrets, IngressRoutes). Leave `argocd/apps/` empty: nothing is enabled.
2. Pin each image to the version running on Docker (`docker inspect`).
3. Validate offline: `kustomize build` / `helm template` on every folder, then `kubeconform` with the CRD schemas (Traefik, cert-manager, ESO). Optionally smoke-test a stack on a throwaway k3d cluster.
4. Write the OpenBao key list (`kv/<namespace>/<app>`) from the ExternalSecrets, to know exactly which `.env` values to import.

**Phase 2 — install k3s next to Docker (bootstrap)** — ✅ done 2026-10-20
0. Host tuning: `fs.inotify.max_user_instances=1024`, `max_user_watches=524288` (`bootstrap/sysctl-90-inotify.conf`; the default 128 instances ran out once k3s ran next to Docker — added 2026-10-20). — ✅
1. Install k3s with `--cluster-init`, the kubelet memory reservations, and the bundled Traefik moved to other ports (e.g. hostPort 8000/8443) so Docker's Traefik keeps 80/443. — ✅ done 2026-10-20 (Traefik `HelmChartConfig` dropped in `/var/lib/rancher/k3s/server/manifests/` before the first start)
2. Create storage classes (`data`, `films`, `data-dynamic`, `films-dynamic`) and namespaces. — ✅ done 2026-10-20 (local-path v0.0.37 requires `pathPattern` to end with `/`: `{{ .PVC.Namespace }}/{{ .PVC.Name }}/`)
3. Install **OpenBao**, initialise it, store the unseal keys + root token in Vaultwarden, unseal, enable the Kubernetes auth method, and import the `.env` values (`kv/<namespace>/<app>`). — ✅ done 2026-10-20 (5 key shares / threshold 3; see README.md "Unseal after a reboot")
4. Install **External Secrets Operator** + the `ClusterSecretStore`. — ✅ done 2026-10-20 (`cert-manager/cloudflare` ExternalSecret synced)
5. Install **cert-manager** + Cloudflare `ClusterIssuer` + wildcard certificates, then the authentik forward-auth Middleware. — ✅ done 2026-10-20. Interim: Docker `authentik_server` publishes `10.0.0.2:9000` (pods can't reach Docker container IPs, and going through Docker Traefik would overwrite `X-Forwarded-Host`), and the Middleware points there until authentik migrates.
6. Install **Argo CD** (+ Image Updater), point the root app-of-apps at `argocd/apps/`, and add the Applications of the bootstrap components only, so Argo CD adopts them. No app stack is enabled yet. — ✅ done 2026-10-20 (repo over HTTPS, branch `kube`, Argo CD login = authentik OIDC, group `admin` = `role:admin`)
7. In Docker Traefik's file provider (`/data/traefik/config.yaml`), add a router per migrated hostname forwarding to k3s Traefik → apps can move one by one with no DNS change. — ✅ done 2026-10-20: service `k3s` → `https://10.0.0.2:8443` (not `127.0.0.1`, which is Docker Traefik's own container) with `insecureSkipVerify`, `lan-only` ipAllowList, routers for `bao` and `argocd`. k3s Traefik trusts `X-Forwarded-For` from `10.42.0.1/32` (host-local traffic is masqueraded to the cni0 gateway), so apps see the real client IP. Verified with a whoami test: real IP, `https` proto, WebSocket upgrade (101), port 80 redirect.

**Phase 3 — migrate apps, one stack at a time**

Per stack: check the running image version still matches the pin (fix it if not) → `docker compose down` → commit its Application into `argocd/apps/` and push to `kube` → manual sync → add its hostnames to the Docker Traefik bridge → test → turn on automated sync → next.

1. Stateless / self-contained: speedtest, sr, mariage, todoapp (with Image Updater), actual, vaultwarden, trilium, lubelogger, mealie, plus openwebui, firefox, meshcentral, gramps. The `apps` namespace is split into one folder + one Application per app (`apps/<app>/`, `apps-<app>`, 2026-10-20) so they migrate one at a time; warracker and guacamole wait for step 5. mariage/todoapp migrate without auto-update (Image Updater git write access comes later); todoapp data stays disposable (emptyDir).
2. Stacks with their own DB: immich (Helm chart), dawarich, ciq, gitea (+ SSH, DinD runner), gramps.
3. Media: the arr suite, jellyfin (with iGPU), navidrome, slskd (port 50300), musiseerr.
4. Monitoring, with all its exporters at once (rewrite the Prometheus scrape config as in §7, config to a ConfigMap, drop cadvisor, fix the Grafana cadvisor queries).
5. Shared `databases` (postgres + redis) together with their consumers: authentik (Helm chart + LDAP outpost), nextcloud, guacamole, warracker. Pods can reach Docker services in the meantime through host-published ports if needed.
6. Home automation (hostNetwork, USB) — test zigbee carefully.

**Phase 4 — cutover**
1. Move Traefik: stop Docker Traefik, reconfigure k3s Traefik on 80/443/22. Also undo the interim pieces of Phase 2:
   - `cluster/base/traefik-config.yaml`: ports 80/443/22, remove `forwardedHeaders.trustedIPs: 10.42.0.1/32` (no bridge any more) — and copy it to `/var/lib/rancher/k3s/server/manifests/`.
   - Check that a **remote** LAN client's IP reaches the pods through ServiceLB (`externalTrafficPolicy: Local`; only tested from the NAS itself so far).
   - Move the `lan-only` ipAllowList (bao, argocd) from Docker Traefik into k3s Middlewares.
   - `/data/traefik/config.yaml` is no longer used.
2. Mailserver (ports 25/143/465/587/993, cert from cert-manager), bind9 (53), minecraft, ddclient, restic (CronJob).
3. Remove watchtower; `docker ps` must be empty → disable Docker (saves ~150 MB). Keep the compose files in git as a fallback for a while.
4. Merge `kube` into `main` and switch every Application (`argocd/root.yaml`, `argocd/*/*.yaml`) and the Image Updater write-back branch from `kube` to `main`.

Rollback at any step: remove the stack's Application from `argocd/apps/` (or `kubectl delete -k …`), then `docker compose up -d` on the same `/data` folders (that's why static PVs on the existing paths matter).
