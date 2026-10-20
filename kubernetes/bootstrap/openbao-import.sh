#!/usr/bin/env bash
# Phase 2 step 3 — import the secrets listed in ../OPENBAO-KEYS.md into OpenBao.
# Run once, on the NAS, after OpenBao is initialised, unsealed and the kv v2 engine is enabled:
#   kubectl -n openbao exec -it openbao-0 -- bao login          # root token, stored in the pod
#   kubectl -n openbao exec -it openbao-0 -- bao secrets enable -version=2 kv
#   ./openbao-import.sh            # add --dry-run to only print paths and property names
# Values never appear on a command line: each path is sent as JSON on stdin.
set -euo pipefail

ENV_FILE=${ENV_FILE:-/data/compose/.env}
DRY_RUN=false; [ "${1:-}" = --dry-run ] && DRY_RUN=true

python3 - "$ENV_FILE" "$DRY_RUN" <<'PY'
import json, subprocess, sys

env_file, dry_run = sys.argv[1], sys.argv[2] == "true"
env = {}
for line in open(env_file):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    env[k.strip()] = v.strip().strip('"').strip("'")

def e(k):
    if k not in env:
        sys.exit(f"missing {k} in {env_file}")
    return env[k]

def container_env(container, key):
    out = subprocess.run(["docker", "inspect", container, "-f", "{{range .Config.Env}}{{println .}}{{end}}"],
                         check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1]
    sys.exit(f"{key} not found in container {container}")

S3_ACCESS_KEY_ID = "a7586b3e917c4addba864b7015a8a98c"   # was hardcoded in restic.yml / monitoring.yml

paths = {
    "shared": {
        "SMTP_PASSWORD": e("SMTP_PASSWORD"),
        "POSTGRES_ADMIN_PASSWORD": e("POSTGRES_ADMIN_PASSWORD"),
        "S3_ACCESS_KEY_ID": S3_ACCESS_KEY_ID,
        "S3_SECRET_ACCESS_KEY": e("RESTIC_AWS_SECRET_ACCESS_KEY"),
    },
    "cert-manager/cloudflare": {"CLOUDFLARE_API_KEY": e("CLOUDFLARE_API_KEY")},
    "authentik/authentik": {
        "AUTHENTIK_SECRET_KEY": e("AUTHENTIK_SECRET_KEY"),
        "AUTHENTIK_POSTGRESQL__PASSWORD": e("AUTHENTIK_DB_PASSWORD"),
        **{k: e(k) for k in env if k.startswith("AUTHENTIK_EMAIL__")},
    },
    "authentik/authentik-ldap": {"AUTHENTIK_TOKEN": e("AUTHENTIK_LDAP_TOKEN")},
    "monitoring/grafana": {"GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": e("AUTHENTIK_GRAFANA_SECRET")},
    "monitoring/jellyfin-exporter": {"JELLYFIN_EXPORTER_API_KEY": e("JELLYFIN_EXPORTER_API_KEY")},
    "media/slskd": {"SLSKD_SLSK_PASSWORD": e("SLSKD_PASSWORD"), "SLSKD_API_KEY": e("SLSKD_API")},
    "media/musiseerr": {"LIDARR_API_KEY": e("LIDARR_API_KEY")},
    "immich/immich": {"DB_PASSWORD": "password", "POSTGRES_PASSWORD": "password"},
    "dawarich/dawarich": {
        "DATABASE_PASSWORD": "password",
        "POSTGRES_PASSWORD": "password",
        "SECRET_KEY_BASE": container_env("dawarich_app", "SECRET_KEY_BASE"),
        "OIDC_CLIENT_SECRET": e("DAWARICH_OIDC_SECRET"),
    },
    "gitea/gitea-runner": {"GITEA_RUNNER_REGISTRATION_TOKEN": e("GITEA_REGISTRATION_TOKEN")},
    "mail/mailserver": {"RELAY_USER": e("MAILJET_EMAIL"), "RELAY_PASSWORD": e("MAILJET_PASSWORD")},
    "nextcloud/nextcloud": {"POSTGRES_PASSWORD": e("NEXTCLOUD_DB_PASSWORD")},
    "apps/openwebui": {"OAUTH_CLIENT_SECRET": e("OPENWEBUI_SECRET")},
    "apps/vaultwarden": {"ADMIN_TOKEN": e("VAULTWARDEN_ADMIN_TOKEN")},
    "apps/mealie": {"OIDC_CLIENT_SECRET": e("AUTHENTIK_MEALIE_SECRET")},
    "apps/meshcentral": {"BACKUPS_PW": e("ADMIN_PASSWORD")},
    "apps/warracker": {
        "DB_PASSWORD": e("WARRACKER_DB_PASSWORD"),
        "SECRET_KEY": e("WARRACKER_SECRET_KEY"),
        "OIDC_CLIENT_SECRET": e("WARRACKER_SECRET"),
    },
    "apps/gramps": {
        "GRAMPSWEB_OIDC_CLIENT_SECRET": e("GRAMPS_OIDC_SECRET"),
        "GRAMPSWEB_SECRET_KEY": e("GRAMPS_SECRET_KEY"),
    },
    "apps/guacamole": {"POSTGRESQL_PASSWORD": e("GUACAMOLE_DB_PASSWORD")},
    "projects/todoapp": {"OIDC_CLIENT_SECRET": e("TODO_OIDC_SECRET")},
    "infra/restic": {"RESTIC_PASSWORD": e("RESTIC_PASSWORD")},
    "ciq/wordpress": {"WORDPRESS_DB_PASSWORD": "password", "MYSQL_PASSWORD": "password"},
}

for path, data in paths.items():
    print(f"kv/{path}: {', '.join(sorted(data))}")
    if dry_run:
        continue
    subprocess.run(["kubectl", "-n", "openbao", "exec", "-i", "openbao-0", "--",
                    "bao", "kv", "put", f"kv/{path}", "-"],
                   input=json.dumps(data), text=True, check=True, stdout=subprocess.DEVNULL)
PY
