# kubernetes/

Kubernetes manifests for the NAS (k3s, single node `nas`), replacing the Docker compose files in the repository root.
The plan and every decision behind it are in [MIGRATION.md](MIGRATION.md). Secrets: [OPENBAO-KEYS.md](OPENBAO-KEYS.md).

Status: **Phase 2 steps 1–3 done** (2026-10-20) — k3s `v1.36.5+k3s1` runs next to Docker, Traefik on 8000/8443/2222, namespaces + storage classes + local-path-provisioner applied, OpenBao installed, unsealed and loaded. `argocd/apps/` is empty.

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

### Unseal after a reboot or pod restart

`bao operator unseal` does **not** read stdin (`-` is taken as the key). Run it 3 times, pasting a different key from Vaultwarden at the hidden prompt each time:

```sh
kubectl -n openbao exec -it openbao-0 -- bao operator unseal
```
5. `kubectl apply -k cluster/secret-store`, then `kubectl apply -k cluster/certs` — wait for both wildcard certificates to be `Ready`.
6. Install Argo CD with Helm (`platform/argocd/values.yaml`), add the repository deploy key (`argocd repo add git@github.com:Fgdou/homelab-compose.git --ssh-private-key-path …`), `kubectl apply -f argocd/root.yaml`.
7. `git mv` the `cluster*` and `platform-*` Applications from `argocd/available/` to `argocd/apps/`, commit, push: Argo CD adopts what was installed by hand.

## Enabling a stack (Phase 3)

1. Check the running version still matches the pin: `docker inspect <container> -f '{{.Image}}'` vs the digest in the manifest. Fix the pin if it changed.
2. Do the stack's migration notes below.
3. `docker compose -f <stack>.yml down`.
4. `git mv argocd/available/<stack>.yaml argocd/apps/`, commit, push.
5. In Argo CD: sync manually, test.
6. Add the Docker Traefik bridge router (`bootstrap/docker-traefik-bridge.yaml`) for each hostname of the stack.
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
| `authentik` | Stop the whole compose stack (server, worker, LDAP outpost). The LDAP outpost keeps its token. |
| `home` | Home Assistant and Music Assistant use `hostNetwork`: ports 8123, 8095, 8097, 21063, 58866-58867 are bound directly on the host. zigbee2mqtt keeps `mqtt://mosquitto:1883` (same namespace). |
| `monitoring` | Migrate with all exporters at once; fix the Grafana dashboards that use cadvisor's `name` label. |
| `mail`, `infra` (bind9) | Only at the Phase 4 cutover: ports 25/143/465/587/993 and 53 are still owned by Docker. |
| `infra` (restic) | Stop the Docker restic before enabling: both would back up on Sunday. |
| `gitea` | SSH listens on 2222 until the Phase 4 cutover (Traefik `ssh` entrypoint). |
| `projects` | mariage / todoapp: Image Updater needs git write access (deploy key with write) to commit new digests. |
| `immich` | Chart is built for v2.6.3, images overridden to v3.3.3: check the server starts and finds the library at `/usr/src/app/upload`. |
| `dawarich` | `SECRET_KEY_BASE` comes from the running container (see OPENBAO-KEYS.md). |

## Phase 4 (cutover) changes in this repo

- `cluster/base/traefik-config.yaml`: `exposedPort` web 80, websecure 443, ssh 22.
- Enable `mail` and `infra`.
