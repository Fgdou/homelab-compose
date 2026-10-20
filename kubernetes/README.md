# kubernetes/

Kubernetes manifests for the NAS (k3s, single node `nas`), replacing the Docker compose files in the repository root.
The plan and every decision behind it are in [MIGRATION.md](MIGRATION.md). Secrets: [OPENBAO-KEYS.md](OPENBAO-KEYS.md).

Status: **Phase 1 done** — everything is written and validated offline. Nothing is deployed; `argocd/apps/` is empty.

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

1. `sudo mkdir -p /etc/rancher/k3s /data/openbao /data/k8s /films/k8s && sudo cp bootstrap/k3s-config.yaml /etc/rancher/k3s/config.yaml`, then install k3s `v1.36.5+k3s1` (command in the file).
2. `kubectl apply -k cluster/base` and `kubectl apply -k platform/local-path`.
3. Install the platform charts with Helm, same versions and values as `argocd/available/platform-*.yaml` (OpenBao, External Secrets, cert-manager), plus `kubectl apply -k platform/openbao` for its PV.
4. OpenBao: `bao operator init` (keep unseal keys + root token in Vaultwarden), `bao operator unseal`, `bao login`, `bao secrets enable -version=2 kv`, enable the Kubernetes auth method with a role `external-secrets` bound to the `external-secrets/external-secrets` ServiceAccount and a read policy on `kv/data/*`. Then `bootstrap/openbao-import.sh` (try `--dry-run` first).
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
