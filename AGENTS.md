# AGENTS.md — operating the NAS cluster

Context for an agent working on this repo or on the live cluster. Details and history live in
[kubernetes/README.md](kubernetes/README.md), the plan and its reasons in [kubernetes/MIGRATION.md](kubernetes/MIGRATION.md),
secret paths in [kubernetes/OPENBAO-KEYS.md](kubernetes/OPENBAO-KEYS.md), status in [kubernetes/PROGRESS.md](kubernetes/PROGRESS.md).

## What runs where

- One host, `nas` (Debian 12, 10.0.0.2), single-node **k3s** `v1.36.5+k3s1` with embedded etcd. Every service runs on k3s
  (migration done 2026-10-21); Traefik (k3s) owns 22/80/443, plus LoadBalancers (klipper) for mail, bind9 (53), minecraft, slskd.
- `docker-old/` = the former compose files, kept for reference/rollback only. Docker is installed but currently
  **disabled and stopped** (seen 2026-10-21). Don't start, stop, enable or disable it without asking the user.
- Repo: `github.com/Fgdou/homelab-compose`, branch `main`. Argo CD follows `main`.

## Access

```sh
export KUBECONFIG=~/.kube/config     # /etc/rancher/k3s/k3s.yaml is root-only
# argocd CLI in --core mode needs the current namespace to be argocd: use a copy of the kubeconfig
cp ~/.kube/config /tmp/kc-argocd && KUBECONFIG=/tmp/kc-argocd kubectl config set-context --current --namespace=argocd
KUBECONFIG=/tmp/kc-argocd argocd app list --core
```

`sudo` works without a password. UIs (LAN only, authentik OIDC): `https://argocd.fgdou.ovh`, `https://bao.fgdou.ovh`.

## How changes are made: GitOps

- Everything under `kubernetes/` is deployed by Argo CD (app-of-apps `kubernetes/argocd/root.yaml` → `kubernetes/argocd/apps/*.yaml`).
  Every Application is `automated: { prune: false, selfHeal: true }`:
  - a push to `main` is live within ~3 min (force it: `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=normal --overwrite`);
  - a manual `kubectl edit/patch` on a managed object is **reverted within seconds**. For break-glass, first
    `argocd app set <app> --core --sync-policy none`, then re-enable with `--sync-policy automated --self-heal`;
  - removing a resource from git does **not** delete it (`prune: false`): delete it by hand as well.
- Validate before pushing: `kubectl kustomize <folder> >/dev/null` (full kubeconform recipe: README "Validate").
- Commit style: short imperative subject, scoped (`projects: …`, `Phase 5.1: …`). Commit and push only when the user asks or agreed to apply.
- Never `helm upgrade/uninstall` the bootstrap releases (openbao, external-secrets, cert-manager, argocd): Argo CD owns them, the Helm metadata is stale.
- Changing a pod template restarts its pods. Apps with a hard dependency (e.g. musiseerr needs lidarr) crash-loop a few times when both restart together; that's expected.

## Conventions (see README "Conventions")

- **Images**: `tag@sha256:digest`, always with `imagePullPolicy: IfNotPresent` (a pod restart, reboot included, must not need DNS or a registry).
  Exception: `projects/kustomization.yaml` `images:` (mariage, todoapp), bumped by Image Updater (git write-back is broken: bump the digest by hand after a push).
- **Storage**: static `local` PVs bound with `volumeName`, PV name `<namespace>-<pvc>`, reclaim `Retain`. Classes: `data` (/data, RAID1 md0),
  `films` (/films, single disk), `nvme` (postgres, `/home/fgdou/postgres` on the root NVMe). `*-dynamic` classes = local-path-provisioner.
- **Secrets**: one `ExternalSecret` per app reading `kv/<namespace>/<app>` (+ `kv/shared`) from OpenBao; property names = env var names (`envFrom`).
  Secret values never go in git. Add a value: `bao kv patch kv/<ns>/<app> KEY=…`, then wait for (or force) the ExternalSecret refresh.
- `enableServiceLinks: false` on pods (service-link env vars broke actual), `readinessProbe` on every serving container.
- New host-device mounts use stable paths (`/dev/serial/by-id/...`, not `/dev/ttyACM0`).

## OpenBao

- Raft storage on `/data/openbao`, **static auto-unseal** since 2026-10-21: key = Secret `openbao/openbao-unseal-key`
  (created by hand, not in git, also kept in Vaultwarden), mounted at `/openbao/unseal/key`, `current_key_id = nas-20261021`.
  The key is in etcd (NVMe), not in the restic backup of /data.
- The 5 old Shamir keys (threshold 3) are now **recovery keys** (generate-root, re-key), in Vaultwarden.
- If the unseal Secret is lost, OpenBao data can't be decrypted: restore the Secret from Vaultwarden
  (`kubectl -n openbao create secret generic openbao-unseal-key --from-file=key=<32-byte file>`).
- `openbao-0` StatefulSet uses `OnDelete`: config changes apply only after `kubectl -n openbao delete pod openbao-0`.
- Check: `kubectl -n openbao exec openbao-0 -- bao status` (expect `Seal Type static`, `Sealed false`).
- When OpenBao is down/sealed, existing Secrets keep working (ExternalSecrets are `deletionPolicy: Retain`); only refreshes stop.
  Afterwards the ClusterSecretStore can stay `InvalidProviderConfig` and some ExternalSecrets `SecretSyncedError` until rechecked:
  `kubectl annotate clustersecretstore openbao force-sync=$(date +%s) --overwrite`, same on each errored ExternalSecret.

## Reboot behaviour (checked 2026-10-21)

A reboot brings everything back without help:
- `/data` and `/films` are `nofail,x-systemd.device-timeout=30s` in fstab (SSH stays reachable if a disk is missing), and
  `/etc/systemd/system/k3s.service.d/10-mounts.conf` (`RequiresMountsFor=/data /films`) keeps k3s off until both are mounted.
  The md0 array is recorded in `/etc/mdadm/mdadm.conf` (initramfs rebuilt).
- Host DNS is **only** 10.0.0.2 = bind9 inside k3s (split-horizon: `*.fgdou.ovh` → 10.0.0.2 on the LAN). CoreDNS forwards to it.
  Until bind9 is up, name resolution fails on the host and in pods; it's why images must be `IfNotPresent`.
  Adding a public resolver was rejected (CoreDNS would randomly return the public IPs).
- Expect a few minutes of crash loops while postgres/redis/authentik come up, then `kubectl get pods -A | grep -v Running` empty
  and `kubectl -n argocd get applications` all Synced/Healthy.
- Known harmless boot warning: initramfs `RESUME=` points at a swap device that no longer exists.

## Backups

- restic CronJob `infra/restic` (Sun 02:00): `/data` → OVH S3 `fgdou-nas-backup`, host `nasrestic`. The Phase 0 restic snapshot is the
  migration backup; don't make ad-hoc tarballs.
- `databases/pg-backups` daily dumps to `/data` (so they're in restic). etcd snapshots: k3s default (12 h, 5 kept) in `/var/lib/rancher/k3s/server/db/snapshots` (not backed up off-host).

## Before touching the cluster

- Read the stack's folder and its notes in README "Migration notes per stack".
- Look before deleting or overwriting anything; PVs are `Retain`, so `kubectl delete -k` keeps the data.
- Don't reboot the host or restart k3s unless the user asks.
