# Docker Compose → Kubernetes migration

Status: **study / plan** — nothing migrated yet.
Snapshot taken 2026-10-20 on the NAS (Ryzen 3 3200G, 4 threads, 32 GB RAM / 29 GiB usable).

TL;DR

- Use **k3s**, single server node, with its bundled Traefik, ServiceLB and local-path provisioner.
- Expect **+1 to +1.5 GB RAM** for k3s itself (≈ +2.5 GB with a full GitOps/monitoring stack). On 32 GB this fits easily.
- The hard parts are not the pods. They are: **storage layout** (two disks with different value), **Traefik labels → IngressRoute**, **docker.sock consumers**, and **host-bound services** (Home Assistant, zigbee USB, mail, DNS, Minecraft).

---

## 1. Current state (inventory)

- 42 compose files, ~85 services defined, **70 containers running**.
- Not running right now (not migrated first, decide later): `audiobookshelf`, `endurain`, `frigate`, `homarr`, `ihatemoney`, `jdownloader`, `matrix` + `element`, `pca`, `wekan`.
- One shared external network `nas`, plus private per-stack networks (`authentik`, `immich`, `dawarich`, `monitoring`, `torrent`, `gitea`, `ciq`, `pca`, `wekan`, `endurain`, `guac`, `gramps-internal`, `warracker`).
- Shared backends on `nas`: `postgres` (authentik, nextcloud, guacamole, warracker, postgres_exporter), `redis` (dawarich, gramps, immich, nextcloud).
- Reverse proxy: Traefik v3.6 with the docker provider (labels), Let's Encrypt wildcard certs via Cloudflare DNS challenge, `authentik` forward-auth middleware.
- Secrets: a single `.env` (gitignored), injected with `${VAR}` interpolation and `env_file`.

### Things to fix before (or during) the migration

These exist today, independent of Kubernetes, and are easier to fix while moving:

| Issue | Why it matters | Decision |
|---|---|---|
| `postgres` data is in `/home/fgdou/postgres` (NVMe root disk) | Not on the RAID1 and not covered by restic. Only the daily dumps in `/data/postgres_backups` are protected. | **Keep it on the NVMe** (faster disk). Static `local` PV on `/home/fgdou/postgres`. Accepted risk: if the NVMe dies, restore from the last daily dump (up to 24 h of data lost). Increase the dump frequency to shrink that window. |
| Named docker volumes: `todoappdata`, `model-cache` (immich), `cache` (bind9) | Live in `/var/lib/docker`, not backed up. `todoappdata` is real data; the others are caches. | **`todoappdata` → `/data/todoapp`** (Phase 0). **Both caches → `emptyDir`**. Immich ML re-downloads its models on each pod restart (slower start). |
| Two LDAP outposts run (`compose-authentik_ldap-1` **and** `ak-outpost-ldap` managed by authentik through docker.sock) | Duplicate. | **Keep the authentik-managed one.** Switch the outpost integration to Kubernetes (ServiceAccount + RBAC) and drop `compose-authentik_ldap-1`. |
| Hardcoded passwords (`password`, `user`) in `ciq`, `pca`, `immich`, `endurain`, `dawarich`; AWS access key ID in `restic`/`monitoring` | Plain text in git. | **Move them into SOPS Secrets with the same values** while converting (no rotation; they are internal-only DB credentials). |
| Unused `.env` keys (`VOUCHERVAULT_*`, `CURSE_API`, `LITELLM_MASTER_KEY`, `LDAP_SEED`, `LDAP_JWT`, `CIQ_AUTHENTIK_*`) | Noise when splitting `.env` into per-namespace Secrets. | **Delete them from `.env` now** (Phase 0). |
| `openwebui`, `audiobookshelf/config`, `jellyseerr`, arr configs (`Radarr`, `Sonarr`, `prowlarr`, `qbittorrent`) are on `/films` | Single disk, not backed up; the arr/jellyseerr configs take time to recreate. | **Leave them on `/films`.** Losing them with the disk is accepted. |

---

## 2. Concept mapping

| Docker Compose | Kubernetes |
|---|---|
| one `*.yml` file / stack | one **namespace** (+ a Kustomize folder) |
| `service` | **Deployment** (stateless) or **StatefulSet** (databases), 1 replica |
| periodic container (`restic`, `pg_backups`, `soularr`) | **CronJob** where the image allows it, else Deployment as today |
| one-per-host container (`node-exporter`) | **DaemonSet** |
| container name / hostname on the network | **Service** (ClusterIP) → DNS `name.namespace.svc.cluster.local` |
| `ports:` on the host | **Service type LoadBalancer** (k3s ServiceLB binds the host port) or `hostNetwork` |
| Traefik labels | **IngressRoute** / **IngressRouteTCP** / **Middleware** CRDs |
| bind mount `/data/...` / `/films/...` | **PersistentVolume + PersistentVolumeClaim** |
| named volume used as cache, `tmpfs`, `shm_size` | **emptyDir** (`medium: Memory` for tmpfs and `/dev/shm`) |
| `environment:` (non-secret) | inline `env:` or **ConfigMap** |
| `.env` / `env_file` / `${VAR}` | **Secret** per namespace (`envFrom` / `secretKeyRef`) |
| `healthcheck` | **livenessProbe / readinessProbe / startupProbe** |
| `depends_on` | no equivalent — pods restart until the dependency is up; use an `initContainer` "wait-for" when an app crashes badly |
| `restart: always / unless-stopped` | default behaviour of Deployments |
| `deploy.resources.limits` | `resources.requests` / `resources.limits` |
| `devices`, `privileged`, `cap_add` | `securityContext` + `hostPath` of type `CharDevice` |
| `dns:` | `dnsConfig` / `dnsPolicy` |
| `extra_hosts` | `hostAliases` |
| YAML anchors (`gramps`) | Kustomize base + patch, or Helm |
| watchtower | removed (see §7) |

---

## 3. Networks

Kubernetes has **one flat network**: every pod can reach every Service of every namespace. There is no "attach to network X".

- **`nas` network** → disappears. Traefik reaches any Service directly.
- **Private networks** (`immich`, `dawarich`, `ciq`, …) → replaced by **NetworkPolicies** (k3s ships a NetworkPolicy controller with flannel). Suggested baseline per namespace:
  - default deny ingress,
  - allow from the same namespace,
  - allow from `kube-system` (Traefik) to the web pods,
  - allow from `monitoring` (Prometheus scraping),
  - allow namespaces using shared postgres/redis → `databases` namespace.
  This is optional at first; the compose setup is not very isolated either (most apps are on `nas`).
- **DNS names change.** Cross-namespace names become `<service>.<namespace>`:
  - `postgres` → `postgres.databases`, `redis` → `redis.databases`, `authentik_server` → `authentik-server.authentik`, `jellyfin` (used by `jellyfin_exporter`), `lidarr` (used by `musiseerr`), `mosquitto` (used by zigbee2mqtt/HA config).
  - Trick to avoid editing every app: create an `ExternalName` Service named `postgres` / `redis` in each consumer namespace pointing to `postgres.databases.svc.cluster.local`.
  - Underscores are not allowed in Service names (`immich_database`, `dawarich_db`, `endurain_postgres`, `authentik_server`) → rename to `-` and update the env vars.
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
| `films` | `/films` (big single disk, re-downloadable) | Retain | media libraries, downloads, caches, ML models, recordings |

### How to bind them: static PVs on the existing folders

Do **not** let a dynamic provisioner create random folders (`pvc-<uuid>`): it breaks the readable `/data/<app>` layout that restic and you rely on.
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

For new apps, the k3s `local-path` provisioner can be configured with two classes whose base paths are `/data/k8s` and `/films/k8s`.

### Shared media folders

`/films/Films`, `/films/music`, `/films/Films/Download`, `/films/slskd/downloads` are mounted by many pods (jellyfin, radarr, sonarr, qbittorrent, lidarr, navidrome, slskd, soularr, jdownloader, audiobookshelf). With a single node, one PV per shared folder mounted by several pods works (`ReadWriteOnce` = one *node*, not one pod). Use `subPath` to mount sub-folders (`films`, `series`, `audiobooks`).
When a second node arrives, these must become NFS (exported from the NAS) or the media pods stay pinned to the NAS node.

### Per-app volume plan

| App | `data` class | `films` class | ephemeral (`emptyDir`) |
|---|---|---|---|
| postgres | `/data/postgres_backups` (data itself stays on the NVMe: local PV on `/home/fgdou/postgres`) | | |
| authentik | `/data/authentik/{media,custom-templates,certs}` | | |
| immich | `/data/immich/core`, `/data/immich/db` | | `model-cache` |
| dawarich | `/data/dawarich/{db_data,shared,public,watched,storage}` | | `/dev/shm` 1Gi (Memory) |
| nextcloud | `/data/nextcloud/code` | | |
| gitea | `/data/gitea` | | runner docker storage |
| mailserver | `/data/mail/{mail-data,mail-state,mail-logs,config}` | | |
| homeassistant | `/data/Homeassistant/{core,media,zigbee2mqtt,mosquitto,musicassistant}` | | |
| monitoring | `/data/monitoring/{prometheus,grafana,ntfy,json_exporter}` | | |
| gramps | `/data/gramps/*` (8 folders → 1 PV + subPaths) | | `/tmp` |
| ciq / pca / wekan / endurain | their `/data/<app>` folders | | |
| small apps (actual, vaultwarden, trilium, mealie, lubelogger, ihatemoney, meshcentral, warracker, guacamole, minecraft, sr, todoapp, lidarr, soularr, navidrome, jellyfin config, bind9, ddclient, homarr, matrix/element) | `/data/<app>` | | |
| arr suite + jellyseerr + qbittorrent + slskd + jdownloader | | `/films/<app>` configs | |
| media libraries | | `/films/Films`, `/films/music` | |
| openwebui, audiobookshelf | | `/films/<app>` | |
| frigate | `/data/frigate/config` | `/films/frigate` | `/tmp/cache` 1Gi, `/dev/shm` 512Mi |
| firefox | | | `/dev/shm` 1Gi |
| bind9 cache | | | `/var/cache/bind` |
| restic | `/data` read-only (`hostPath`) | | |

Host files currently bind-mounted (`/etc/localtime`, `/etc/timezone`, `/run/dbus`, `/run/udev`, `/proc`, `/sys`, `/`) → `hostPath` volumes, or simply `TZ=Europe/Paris` for the timezone.

### Backups

Nothing changes for restic: it still backs up `/data` from the host. Postgres data stays outside restic (on the NVMe); it is only protected by the dumps in `/data/postgres_backups`. Add `/data/k8s` (manifests are in git anyway) and, if you use them, sealed-secrets keys. Do **not** back up `/var/lib/rancher` blindly; back up the k3s datastore token + `server/db` snapshot instead (`k3s etcd-snapshot` if etcd is used).

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

### Certificates

Two options:

1. **Keep Traefik ACME** (Cloudflare DNS challenge, wildcard `*.fgdou.ovh` and `*.ciq-panier.fr`): needs a PVC for `acme.json` and Traefik as a single replica. Simplest, closest to today.
2. **cert-manager** (recommended): `ClusterIssuer` with Cloudflare DNS01, two wildcard `Certificate`s stored as Secrets, used as Traefik's default TLS store.
   Bonus: the **mailserver** gets its certificate from the same Secret instead of reading Traefik's `acme.json` (today `/data/traefik/acme.json` is mounted into the mail container).
   Cost: ~100–150 MB RAM.

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

- `authentik@docker` forward-auth → one `Middleware` in the `authentik` namespace, `forwardAuth.address: http://authentik-server.authentik:9000/outpost.goauthentik.io/auth/traefik`, same `authResponseHeaders`. Apps using it today: firefox, frigate, jdownloader, lubelogger, navidrome, prometheus, radarr, sonarr, prowlarr, qbittorrent, lidarr, slskd, musiseerr, trilium, zigbee2mqtt, traefik dashboard. Add adminer (was exposed on host port 8080 without auth).
- **Navidrome** two routers (path-based bypass of auth for `/rest` and `/share`) → two routes in the same IngressRoute, only one with the middleware.
- **Gitea SSH** `HostSNI(*)` on `ssh` → `IngressRouteTCP`.
- **Traefik dashboard** (`api@internal`) → IngressRoute to `api@internal` with the authentik middleware; drop `api.insecure`.
- The empty file provider `/data/traefik/config.yaml` is useful during the transition (see §8).

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

- Split `.env` into **one Secret per namespace** containing only what the namespace uses (e.g. `authentik` gets `AUTHENTIK_*`; `apps` gets `VAULTWARDEN_ADMIN_TOKEN`, `SMTP_PASSWORD`, …). Shared values (`SMTP_PASSWORD`, `POSTGRES_ADMIN_PASSWORD`) are duplicated in the namespaces that need them.
- Compose defaults like `${POSTGRES_USER:-postgres}` / `${APP_MEMORY_LIMIT:-4G}` must be **resolved** into literal values (Kubernetes does no interpolation; `$(VAR)` only references other env vars of the same container).
- `env_file: .env` (authentik server/worker, immich ML) injects *all* keys today → use `envFrom` on a dedicated Secret with only the needed keys.
- Storing secrets in git: use **SOPS + age** (works with Kustomize/Flux, no extra pod) or **Sealed Secrets** (one ~30 MB controller). Never commit plain `Secret` manifests.
- Non-secret config (OIDC client IDs, URLs) can stay inline in the Deployment.

---

## 7. Special cases

| Service | Problem | Solution |
|---|---|---|
| traefik | docker.sock for the docker provider | replaced by k3s Traefik + kubernetesCRD provider |
| authentik worker | docker.sock, `user: root`, manages outposts through Docker | Use the **official Helm chart**, switch the outpost integration to *Kubernetes* (ServiceAccount + RBAC), keep a single LDAP outpost |
| gitea_runner | docker.sock to run CI jobs | act_runner + **docker-in-docker sidecar** (privileged), or the runner's Kubernetes mode |
| homarr | docker.sock integration | Homarr 1.x has a Kubernetes integration; or drop the integration (not running anyway) |
| watchtower | auto-update `mariage`, `todoapp` every minute | No docker socket anymore. Options: `imagePullPolicy: Always` + a CronJob running `kubectl rollout restart`, **Keel**, or Flux image automation. Better long-term: CI pushes a versioned tag and updates the manifest |
| cadvisor | container metrics | **removed**: the kubelet embeds cAdvisor (`/metrics/cadvisor`). Saves ~220 MB |
| node-exporter | host mounts | DaemonSet with `hostPID`, `hostNetwork`, hostPath `/proc` `/sys` `/` |
| prometheus | static targets on docker names | add `kubernetes_sd_configs` (pods/services/nodes) + scrape kubelet/cAdvisor; RBAC to read the API. Expect more series (k8s metrics) → a bit more RAM |
| zigbee2mqtt | `/dev/ttyACM0` | hostPath `type: CharDevice` + `privileged: true` (or a device plugin), pinned to the NAS node |
| homeassistant | `privileged`, `/run/dbus`, mDNS/HomeKit | `hostNetwork`, privileged, hostPath `/run/dbus` |
| musicassistant | `SYS_ADMIN`, `DAC_READ_SEARCH`, `apparmor:unconfined` | `securityContext.capabilities.add`, `appArmorProfile: Unconfined`, `hostNetwork` |
| jellyfin | no GPU today (software transcoding) | optionally mount `/dev/dri` (the Vega iGPU, `renderD128`) → big CPU savings on this 4-thread CPU |
| frigate | `shm_size`, tmpfs | emptyDir Memory for `/dev/shm` and `/tmp/cache` (counts against the pod's memory limit!) |
| dawarich | `shm_size: 1G`, cpu 0.5 / mem 4G limit, `stdin_open`/`tty` | emptyDir Memory, `resources.limits`, `stdin: true`/`tty: true` |
| minecraft | `MAX_MEMORY=4G`, autopause, tty | memory limit ≥ 5Gi (JVM overhead) else OOMKill; `stdin/tty: true` |
| mailserver | `hostname: mail.fgdou.ovh`, `dns: 8.8.8.8`, uses Traefik's acme.json | `hostname`+`subdomain` or `setHostnameAsFQDN`, `dnsConfig`, cert Secret from cert-manager; `terminationGracePeriodSeconds: 60` |
| restic | `privileged`, internal cron | Keep as a Deployment (image has its own cron), or rewrite as a CronJob with the plain `restic` image |
| nextcloud | custom command waiting for authentik | keep as is, or move to an `initContainer` |
| gramps | YAML anchor shared by web + celery | Kustomize: one base Deployment, patch command for celery |
| immich | official compose | **official Helm chart** (immich-charts), or plain manifests |
| `:latest` images (arr suite, wordpress, flaresolverr, adminer…) | | pin versions; with `:latest` set `imagePullPolicy: Always` |

---

## 8. Proposed namespaces

| Namespace | Content |
|---|---|
| `kube-system` | Traefik (bundled), CoreDNS, ServiceLB, local-path, metrics-server |
| `cert-manager` | cert-manager (optional) |
| `databases` | postgres, adminer, pg-backups, redis |
| `authentik` | server, worker, ldap outpost, forward-auth Middleware |
| `monitoring` | prometheus, grafana, ntfy, node-exporter, blackbox, json/jellyfin/postgres/s3 exporters |
| `media` | jellyfin, navidrome, audiobookshelf, jdownloader, radarr, sonarr, lidarr, prowlarr, flaresolverr, qbittorrent, jellyseerr, slskd, soularr, musiseerr |
| `home` | homeassistant, zigbee2mqtt, mosquitto, musicassistant, frigate |
| `immich`, `dawarich`, `gitea`, `mail`, `nextcloud` | one per big stack |
| `apps` | actual, openwebui, vaultwarden, trilium, mealie, ihatemoney, lubelogger, speedtest, homarr, firefox, meshcentral, warracker, gramps, guacamole, matrix/element, wekan, endurain |
| `projects` | sr, mariage, todoapp |
| `games` | minecraft |
| `infra` | bind9, ddclient, restic |
| `ciq`, `pca` | external websites (WordPress + MySQL) |

Repository layout suggestion:

```
kubernetes/
├── MIGRATION.md
├── cluster/            # k3s config, HelmChartConfig traefik, cert-manager issuers, storage classes
├── databases/          # kustomization.yaml, postgres.yaml, redis.yaml, pv.yaml, secret.sops.yaml
├── authentik/
├── media/
└── ...                 # one folder per namespace
```

Apply with `kubectl apply -k kubernetes/<ns>` at first. GitOps (Flux ≈ 200–300 MB, Argo CD ≈ 500 MB–1 GB) can come later; Flux is the lighter choice.

---

## 9. RAM impact

### Measured today

- `docker stats` on 2026-10-20: **17.3 GiB** for the 70 running containers, + ~220 MB for `dockerd`/`containerd`. Your ~20 GB figure includes the rest of the host (kernel, other processes).
- Biggest consumers: minecraft 1.8 G, grampsweb 1.3 G, homeassistant 1.1 G, postgres 850 M, authentik server 790 M, dawarich db 745 M, openwebui 715 M, immich 705 M, ciq mysql 625 M, firefox 605 M.
- 9 stacks are stopped; frigate alone can take 0.5–1.5 GB if restarted.

### Workloads: same RAM

The apps use the same memory in a pod as in a container — same image, same process. Kubernetes adds nothing per pod except a tiny `pause` container (~0.5–1 MB each, ~70 MB total).

### Overhead of the cluster itself

| Component | k3s (single node) | kubeadm "full" k8s |
|---|---|---|
| API server + controller-manager + scheduler + kubelet + kube-proxy | 500–800 MB (one process) | 600–1000 MB |
| datastore | SQLite: ~0 / embedded etcd: +100–200 MB | etcd: 150–300 MB |
| CNI | flannel (in k3s process) | Calico 150–250 MB / Cilium 300–500 MB |
| CoreDNS | 30–70 MB | 2 replicas: 60–140 MB |
| metrics-server, local-path, ServiceLB pods | ~100 MB | add-ons to install |
| **Total cluster overhead** | **≈ 0.7–1.1 GB** | **≈ 1.2–2.2 GB** |

### Freed

| Removed | Saved |
|---|---|
| cadvisor (kubelet has it) | ~220 MB |
| watchtower | ~35 MB |
| docker daemon (once everything is migrated; k3s uses its own containerd) | ~150 MB |
| duplicated LDAP outpost | ~40–75 MB |
| **Total** | **≈ 0.45 GB** |

### Optional add-ons

| Add-on | RAM |
|---|---|
| cert-manager | 100–150 MB |
| SOPS (no pod) / Sealed Secrets | 0 / ~30 MB |
| Flux / Argo CD | 200–300 MB / 0.5–1 GB |
| kube-state-metrics + extra Prometheus series | 150–400 MB |
| kube-prometheus-stack instead of your own prometheus/grafana | +0.5–1 GB vs today |
| Longhorn (replicated storage) | 1–1.5 GB → **not worth it on one node** |

### Result

| Scenario | Containers | Estimate | vs today |
|---|---|---|---|
| Today (Docker) | 17.3 GiB | ~20 GB host | — |
| k3s minimal (Traefik, ServiceLB, local PVs, SOPS) | 17.3 GiB | **~21 GB** | **+0.5 to +1 GB** |
| k3s + cert-manager + Flux + kube-state-metrics | 17.3 GiB | **~21.5–22 GB** | **+1.5 to +2 GB** |
| kubeadm k8s + Calico + same add-ons | 17.3 GiB | ~22.5–23 GB | +2.5 to +3 GB |

On 32 GB this leaves **~10 GB** free, used by Linux as page cache (13 GiB of cache today — this is what keeps Jellyfin/Immich/Postgres fast, so don't fill it up with limits "just because").

During the migration Docker and k3s run side by side, but each app only runs once (stop the compose service before starting the pod), so the peak is today + ~1 GB.

### Requests / limits advice

- Set **memory requests** ≈ current usage (from the table above) so the scheduler knows the real picture once there are several nodes.
- Set **memory limits** only on apps known to leak or spike (dawarich 4G, mealie 1G, minecraft 5G, immich ML, openwebui, firefox). A limit too close to usage = OOMKill loop.
- Avoid CPU limits (throttling on a 4-thread CPU hurts more than it helps); use CPU requests only.
- k3s kubelet: reserve memory for the system (`--kube-reserved=memory=512Mi --system-reserved=memory=1Gi`) and keep eviction thresholds sane, otherwise the kubelet can evict pods under page-cache pressure.

---

## 10. k3s or k8s?

**Recommendation: k3s.**

| | k3s | kubeadm (vanilla k8s) |
|---|---|---|
| Install | one binary, `curl -sfL https://get.k3s.io \| sh -` | kubeadm + containerd + CNI + add-ons |
| RAM overhead | ~0.7–1.1 GB | ~1.2–2.2 GB |
| Bundled | Traefik, ServiceLB, local-path, metrics-server, flannel, NetworkPolicy controller, Helm controller | nothing |
| Conformance | CNCF certified — **same API, same manifests** | reference |
| Upgrades | replace binary (or system-upgrade-controller) | `kubeadm upgrade` per minor version, more steps |
| Multi-node | `k3s agent` with a join token; HA with 3 servers + embedded etcd | same capabilities, more setup |
| Real-world fit | homelab / edge / small clusters | big clusters, very specific needs |

The 4-thread Ryzen 3 is the real constraint: a vanilla control plane burns noticeably more CPU in the background (etcd, separate components) than k3s.

### Planning for more servers later

- Manifests written for k3s run on any Kubernetes, so the choice is **not a lock-in**.
- Start the server with **`--cluster-init`** (embedded etcd) if you think you'll go HA (3 control-plane nodes). An existing SQLite k3s can also be converted later by restarting with `--cluster-init`, so starting with SQLite is fine too.
- Adding a **worker** node: `k3s agent --server https://nas:6443 --token …` — trivial.
- The real multi-node problem is **storage, not the distribution**:
  - `/data` (RAID1) and `/films` only exist on the NAS → pods using them stay pinned there via the PV `nodeAffinity`. That's fine: the NAS stays the "storage node", other nodes run stateless/CPU-heavy pods (immich ML, minecraft, CI runners, transcoding).
  - To let pods move freely: export `/data` and `/films` over **NFS** from the NAS (nfs-subdir-external-provisioner / csi-driver-nfs). Avoid NFS for databases (postgres, mysql, mongo, sqlite apps) — keep them pinned on local disk.
  - Longhorn/Ceph only make sense with 3+ nodes with their own disks.
- Hardware-bound pods (zigbee USB, Home Assistant, Jellyfin with iGPU) → `nodeSelector` on the NAS.
- Ingress on several nodes: ServiceLB runs on every node; point DNS/router at one, or add kube-vip / MetalLB for a floating IP.

Alternatives considered: **k0s** (similar to k3s, less homelab ecosystem), **MicroK8s** (snap-based, heavier), **Talos** (excellent but needs its own OS — not suitable for a NAS that also runs mdadm RAID and host services).

---

## 11. Migration plan

Docker and k3s can coexist (k3s uses its own containerd). The only conflicts are host ports (80, 443, 22, 53, 25…).

**Phase 0 — prepare (on Docker)**
1. Move `todoappdata` → `/data/todoapp`. Postgres stays on `/home/fgdou/postgres`; consider more frequent dumps.
2. Remove the compose LDAP outpost (keep the authentik-managed one), pin `:latest` images, delete the unused `.env` keys.
3. Take a full restic snapshot + postgres dump.

**Phase 1 — install k3s next to Docker**
1. Install k3s with the bundled Traefik moved to other ports (e.g. NodePort/hostPort 8000/8443) so Docker's Traefik keeps 80/443.
2. Create storage classes, PVs, namespaces, Secrets (SOPS), cert-manager + wildcard certs, authentik Middleware.
3. In Docker Traefik's file provider (`/data/traefik/config.yaml`), add a router per migrated hostname forwarding to `https://127.0.0.1:8443` → apps can move one by one with no DNS change.

**Phase 2 — migrate apps, one stack at a time** (`docker compose down` → `kubectl apply -k` → test → next)
1. Stateless / self-contained: speedtest, sr, mariage, todoapp, actual, vaultwarden, trilium, lubelogger, mealie, warracker…
2. Stacks with their own DB: immich, dawarich, ciq, gitea (+ SSH), wekan, endurain, gramps.
3. Media: the arr suite, jellyfin, navidrome, slskd (port 50300), musiseerr.
4. Monitoring (rewrite Prometheus scrape config, drop cadvisor).
5. Shared `databases` (postgres + redis) together with their consumers: authentik, nextcloud, guacamole, warracker. Pods can reach Docker services in the meantime through host-published ports if needed.
6. Home automation (hostNetwork, USB) — test zigbee carefully.

**Phase 3 — cutover**
1. Move Traefik: stop Docker Traefik, reconfigure k3s Traefik on 80/443/22.
2. Mailserver (ports 25/143/465/587/993, cert from Secret), bind9 (53), minecraft, ddclient, restic.
3. Remove watchtower; `docker ps` must be empty → disable Docker (saves ~150 MB). Keep the compose files in git as a fallback for a while.

Rollback at any step: `kubectl delete -k …` then `docker compose up -d` on the same `/data` folders (that's why static PVs on the existing paths matter).
