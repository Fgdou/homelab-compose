# kubernetes/

Kubernetes manifests for the NAS (k3s, single node `nas`), replacing the Docker compose files in the repository root.
The plan and every decision behind it are in [MIGRATION.md](MIGRATION.md). Secrets: [OPENBAO-KEYS.md](OPENBAO-KEYS.md).

Status: **Phase 2 done** (2026-10-20) — k3s `v1.36.5+k3s1` next to Docker (Traefik on 8000/8443/2222), OpenBao, External Secrets, cert-manager, Argo CD + Image Updater installed; Argo CD follows the `kube` branch over HTTPS and manages the `cluster*` and `platform-*` Applications (`argocd/apps/`); the Docker Traefik bridge forwards `bao` and `argocd`. No app stack enabled yet (**next: Phase 3**). UIs (LAN only, authentik OIDC): `https://bao.fgdou.ovh`, `https://argocd.fgdou.ovh`.

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
| `<namespace>/` | one folder per namespace (`databases`, `authentik`, `monitoring`, `media`, `home`, `immich`, `dawarich`, `gitea`, `mail`, `nextcloud`, `apps`, `projects`, `games`, `infra`, `ciq`) | same name |

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
for d in cluster/* platform/* databases authentik monitoring media home immich dawarich gitea mail nextcloud apps projects games infra ciq; do
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
6. Argo CD (done 2026-10-20): repo is public → `repoURL: https://github.com/Fgdou/homelab-compose.git`, no repository credentials; Applications follow `targetRevision: kube` until the branch is merged.
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
- Bridged today: `bao.fgdou.ovh`, `argocd.fgdou.ovh` (both `lan-only`).

### Left over from the bootstrap

- ~~Disable the Argo CD local admin~~ — done 2026-10-20 (OIDC login verified): `admin.enabled: false`, `argocd-initial-admin-secret` deleted.
  Break-glass if authentik is down: the CLI still works with `argocd ... --core` (kubeconfig). For the UI: `kubectl -n argocd patch cm argocd-cm -p '{"data":{"admin.enabled":"true"}}'`, set a password with `argocd account bcrypt --password <pw>` → `kubectl -n argocd patch secret argocd-secret -p '{"stringData":{"admin.password":"<bcrypt>","admin.passwordMtime":"'$(date +%FT%TZ)'"}}'`, log in, then sync `platform-argocd` to revert.
- Helm release metadata (`sh.helm.release.v1.*` Secrets in openbao, external-secrets, cert-manager, argocd) is now stale: Argo CD owns the resources. Never `helm upgrade/uninstall` these releases; delete the release Secrets (only metadata) to avoid confusion.
- `applicationSet.enabled: false` is ignored by chart 10.10.5 (the controller runs): find the right key.
- Turn on `automated: { prune: false, selfHeal: true }` in the bootstrap Applications once trusted.
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

Things that the manifests cannot do by themselves, to do on migration day.

| Stack | Before enabling |
|---|---|
| all | Remove the stack's watchtower / Traefik-label dependency; the Docker Traefik bridge forwards its hostnames. |
| `databases` | Migrate together with all its consumers (authentik, nextcloud, guacamole, warracker, postgres-exporter). |
| `nextcloud` | In `/data/nextcloud/code/config/config.php`: `'dbhost' => 'postgres'` → `'postgres.databases'`, redis `'host' => 'redis'` → `'redis.databases'`. |
| `media` | Jellyfin LDAP plugin (`/data/Jellyfin/data/plugins/configurations/LDAP-Auth.xml`): `<LdapServer>authentik_ldap</LdapServer>` → `authentik-ldap.authentik`. Enable VAAPI (`/dev/dri/renderD128`) in Jellyfin's playback settings. |
| `authentik` | Stop the whole compose stack (server, worker, LDAP outpost). The LDAP outpost keeps its token. Switch `authentik/middleware.yaml` back to `http://authentik-server.authentik/...` (see its comment) in the same commit; then drop the interim `ports: 10.0.0.2:9000` from `authentik.yml`. |
| every app behind authentik | A hostname that has no authentik Proxy Provider yet (e.g. Argo CD, adminer) gets a **404** from forward-auth: create the provider (Forward auth, single application) and add it to the embedded outpost first. |
| `home` | Home Assistant and Music Assistant use `hostNetwork`: ports 8123, 8095, 8097, 21063, 58866-58867 are bound directly on the host. zigbee2mqtt keeps `mqtt://mosquitto:1883` (same namespace). |
| `monitoring` | Migrate with all exporters at once; fix the Grafana dashboards that use cadvisor's `name` label. |
| `mail`, `infra` (bind9) | Only at the Phase 4 cutover: ports 25/143/465/587/993 and 53 are still owned by Docker. |
| `infra` (restic) | Stop the Docker restic before enabling: both would back up on Sunday. |
| `gitea` | SSH listens on 2222 until the Phase 4 cutover (Traefik `ssh` entrypoint). |
| `projects` | mariage / todoapp: Image Updater needs git write access (deploy key with write) to commit new digests. |
| `immich` | Chart is built for v2.6.3, images overridden to v3.3.3: check the server starts and finds the library at `/usr/src/app/upload`. |
| `dawarich` | `SECRET_KEY_BASE` comes from the running container (see OPENBAO-KEYS.md). |

## Phase 4 (cutover) changes in this repo

- `cluster/base/traefik-config.yaml`: drop `forwardedHeaders.trustedIPs` (bridge gone), copy the file to `/var/lib/rancher/k3s/server/manifests/`; add k3s `lan-only` Middlewares for bao and argocd.
- Switch `targetRevision: kube` → `main` (and the Image Updater branch) after merging.

- `cluster/base/traefik-config.yaml`: `exposedPort` web 80, websecure 443, ssh 22.
- Enable `mail` and `infra`.
