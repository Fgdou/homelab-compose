# Migration progress

Status of every stack, and the per-app procedure used in Phase 3. The plan is in [MIGRATION.md](MIGRATION.md) §11; detailed notes per migrated app (switch time, problems found) are in [README.md](README.md) "Migrated stacks".

Status: ✅ migrated · 🔄 on k3s, waiting for confirmation · ⏳ to do

## Phase 3 — apps

| Step | Stack | Application | Docker compose file | Status | Date |
|---|---|---|---|---|---|
| 3.0 | redis (shared) | `databases-redis` | `redis.yml` (stays until the last consumer moves) | ✅ | 2026-10-20 |
| 3.1 | speedtest | `apps-speedtest` | `speedtest.yml` | ✅ | 2026-10-20 |
| 3.1 | firefox | `apps-firefox` | `firefox.yml` | ✅ | 2026-10-20 |
| 3.1 | actual | `apps-actual` | `actual_budget.yml` | ✅ | 2026-10-20 |
| 3.1 | trilium | `apps-trilium` | `trilium.yml` | ✅ | 2026-10-20 |
| 3.1 | lubelogger | `apps-lubelogger` | `lubelogger.yml` | ✅ | 2026-10-20 |
| 3.1 | mealie | `apps-mealie` | `mealie.yml` | ✅ | 2026-10-20 |
| 3.1 | openwebui | `apps-openwebui` | `ai.yml` | ✅ | 2026-10-20 |
| 3.1 | meshcentral | `apps-meshcentral` | `meshcentral.yml` | ✅ | 2026-10-20 |
| 3.1 | gramps (web + celery) | `apps-gramps` | `gramps.yml` | ✅ | 2026-10-20 |
| 3.1 | vaultwarden | `apps-vaultwarden` | `vaultwarden.yml` | ⏳ | |
| 3.1 | sr, mariage, todoapp | `projects` | `projects.yml` | ⏳ | |
| 3.2 | immich | `immich` | `immich.yml` | ⏳ | |
| 3.2 | dawarich | `dawarich` | `dawarich.yaml` | ⏳ | |
| 3.2 | ciq | `ciq` | `ciq.yml` | ⏳ | |
| 3.2 | gitea (+ SSH, runner) | `gitea` | `gitea.yaml` | ⏳ | |
| 3.3 | media (arr, jellyfin, navidrome, slskd, musiseerr) | `media` | `jellyfin.yml`, `navidrome.yml`, `torrent.yml`, … | ⏳ | |
| 3.4 | monitoring | `monitoring` | `monitoring.yml` | ⏳ | |
| 3.5 | postgres, adminer, pg-backups | `databases` | `postgres.yml` | ⏳ | |
| 3.5 | authentik (+ LDAP outpost) | `authentik` | `authentik.yml` | ⏳ | |
| 3.5 | nextcloud | `nextcloud` | `nextcloud.yml` | ⏳ | |
| 3.5 | guacamole | `apps-guacamole` | `guacamole.yml` | ⏳ | |
| 3.5 | warracker | `apps-warracker` | `warracker.yml` | ⏳ | |
| 3.6 | home (homeassistant, zigbee2mqtt, mosquitto, musicassistant) | `home` | `homeassistant.yml` | ⏳ | |

## Phase 4 — cutover (not on k3s yet)

| Stack | Application | Docker compose file | Status |
|---|---|---|---|
| traefik → k3s Traefik on 80/443/22 | `cluster` | `traefik.yaml` | ⏳ |
| mailserver | `mail` | `mailserver.yml` | ⏳ |
| bind9, ddclient, restic | `infra` | `bind9.yaml`, `ddclient.yaml`, `restic.yml` | ⏳ |
| minecraft | `games` | `minecraft.yml` | ⏳ |
| meshcentral restart (new cert) | `apps-meshcentral` | — | ⏳ |
| watchtower removed, Docker disabled | — | `watchtower.yml` | ⏳ |

## Per-app template (Phase 3)

Copy for each app; `<app>` = stack name, `<file>` = its compose file, `<services>` = its compose services.

```bash
export KUBECONFIG=~/.kube/config
# argocd --core needs the current namespace to be argocd: use a copy of the kubeconfig
cp ~/.kube/config /tmp/kc-argocd && KUBECONFIG=/tmp/kc-argocd kubectl config set-context --current --namespace=argocd
alias argocd-core='KUBECONFIG=/tmp/kc-argocd argocd'
```

1. **Preflight** (Docker still serving)
   - Image matches the pin: `docker inspect <container> --format '{{.Image}}'` and `docker image inspect <image> --format '{{json .RepoDigests}}'` vs the `@sha256:` in `kubernetes/<path>/*.yaml`.
   - Dependencies are on k3s and healthy (e.g. `redis.databases`), OpenBao unsealed (`kubectl -n openbao exec openbao-0 -- bao status`), `argocd-core app list --core` all Synced/Healthy.
   - Files owned by the uid the pod runs as (`sudo ls -ln /data/<app>`, `docker exec <container> id`).
2. **Enable**: `git mv argocd/available/apps-<app>.yaml argocd/apps/`, commit `Phase 3.x: enable apps-<app>`, push to `kube`. Manual sync only (no `syncPolicy` yet).
3. **Secrets first**: `argocd-core app sync apps-<app> --core --resource external-secrets.io:ExternalSecret:<ns>/<app>`, then compare the synced Secret with the running container's env (`kubectl get secret -o go-template` with `base64decode` vs `docker inspect --format '{{range .Config.Env}}…'`).
4. **Switch**: `docker compose -f <file> rm -sf <services>` → `argocd-core app sync apps-<app> --core` → `kubectl -n <ns> rollout status deploy/<…>`.
5. **Bridge**: add a `k3s-<app>` router to `/data/traefik/config.yaml` (`Host(...)`, `entryPoints: [websecure]`, `service: k3s`, `tls: {}`; `middlewares: [lan-only]` only for admin UIs). Edit in place with `sudo tee`.
6. **Test**: public URL answers, login (OIDC redirect to `auth.fgdou.ovh`), data is the same as before, logs clean, background workers connected.
7. **Confirm**: the user checks the app → only then continue.
8. **Record**: row in README.md "Migrated stacks" + "Bridged today", status here → ✅, commit `Phase 3.x: <app> migrated`, push.
9. Next app. (Automated sync per app comes later, MIGRATION.md §11.)

Rollback: `git mv` the Application back to `available/`, push, `kubectl delete -k kubernetes/<path>` (PVs are `Retain`), remove the bridge router, `docker compose -f <file> up -d`.
