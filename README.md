# SSB — Simple Swarm Backup

A production-ready Bash script that backs up Docker Swarm node data (volumes
and databases) to a network-mounted (NFS) backup target.  Runs independently
on every node via cron — no central scheduler, no shared state.

---

## Features

- **File backup** — rsyncs `/srv/docker` to a dated output directory
- **Database backup** — performs logical dumps inside containers via `docker exec`
  - MySQL / MariaDB (`mysqldump`)
  - PostgreSQL (`pg_dump` / `pg_dumpall`)
- **Compressed DB dumps** — dumps are written locally, gzipped, then copied to NFS
- **Label-driven** — opt containers in with a single Docker label
- **GlusterFS backup** — optional, enabled on exactly one node
- **Retention** — automatically removes old dated per-host backups and old GlusterFS dated backups (on the designated GlusterFS node)
- **Lock file** — prevents overlapping cron runs; detects and recovers stale locks
- **Healthcheck** — sends a curl ping on fully successful completion
- **Dry-run mode** — shows what would happen without writing any files
- **Structured logging** — one log file per backup run, plus a useful exit code

---

## Quick Start

```bash
# 1. Copy the script
sudo cp ssb.sh /usr/local/sbin/ssb.sh
sudo chmod +x /usr/local/sbin/ssb.sh

# 2. Create a local JSON config file next to the script
cd /usr/local/sbin
sudo cp ssb.json.example ssb.json
sudo nano ssb.json

# 3. Test with --dry-run
/usr/local/sbin/ssb.sh --dry-run

# 4. Add to root crontab (runs at 02:00 every night)
echo "0 2 * * * /usr/local/sbin/ssb.sh >> /var/log/ssb.log 2>&1" \
  | sudo crontab -
```

---

## Configuration

`ssb.sh` loads configuration from a JSON file in the same directory as the script by default.

- Default config file: `ssb.json` (in script directory)
- Optional config file via `--config <path>` (absolute path or relative to script directory)
- Define multiple servers in one JSON file under `servers`
- The script selects config by hostname (`hostname -s`; fallback to full hostname)

Local config files are ignored by git via `.gitignore`, so they are not
affected by pull/push.

### Example

```bash
# Uses ./ssb.json (if present)
./ssb.sh --dry-run

# Uses ./ssb.prod.json (relative to script directory)
./ssb.sh --config ssb.prod.json --dry-run

# Uses /etc/ssb/config.json (absolute path)
./ssb.sh --config /etc/ssb/config.json --dry-run
```

### JSON config structure

Use `default` for shared settings and `servers.<hostname>` for host-specific overrides.

For `docker_exclude_dirs`, values are merged: the effective list is `default.docker_exclude_dirs` plus `servers.<hostname>.docker_exclude_dirs`.

```json
{
  "default": {
    "backup_base": "/mnt/nas01backup",
    "retention_days": 5,
    "existing_backup_action": "overwrite",
    "healthcheck_url": "",
    "docker_src": "/srv/docker",
    "docker_exclude_dirs": ["service-a/tmp"],
    "backup_gluster": false,
    "gluster_dest_name": "gluster01",
    "gluster_src": "/mnt/gluster01",
    "gluster_exclude_dirs": ["shared/tmp"]
  },
  "servers": {
    "docker01": {
      "backup_gluster": true
    }
  }
}
```

Available variables in JSON config (`default` and server overrides):

| Variable | Default | Description |
|---|---|---|
| `backup_base` | `/mnt/nas01backup` | Root of the NFS backup target |
| `retention_days` | `5` | Days to keep per-host and GlusterFS dated directories |
| `existing_backup_action` | `"overwrite"` | `"overwrite"` or `"keep"` when today's backup already exists |
| `healthcheck_url` | `""` | URL to curl on success (e.g. `https://hc-ping.com/<uuid>`) |
| `docker_src` | `/srv/docker` | Docker volume source directory |
| `docker_exclude_dirs` | `[]` | Paths relative to `docker_src` to exclude from rsync (merged: default + server list) |
| `backup_gluster` | `false` | Set to `true` on the one node responsible for GlusterFS |
| `gluster_dest_name` | `"gluster01"` | Output folder name under `backup_base` for GlusterFS |
| `gluster_src` | `/mnt/gluster01` | GlusterFS source directory |
| `gluster_exclude_dirs` | `[]` | Paths relative to `gluster_src` to exclude from rsync |

---

## Container Labels

Add labels to your Docker containers or Swarm service definitions to enable
database backups.

| Label | Value | Effect |
|---|---|---|
| `ssb.backup-db` | `mysql` or `mariadb` | Dump MySQL / MariaDB databases |
| `ssb.backup-db` | `postgresql` or `postgres` | Dump PostgreSQL databases |
| `ssb.backup-db-names` | `db1,db2` | Specific databases to dump (optional) |
| `ssb.backup-db-username` | `ENV_VAR_NAME` | Env var name inside container for DB username (optional override) |
| `ssb.backup-db-password` | `ENV_VAR_NAME` | Env var name inside container for DB password (optional override) |

Without `ssb.backup-db-names` the script performs a full dump of all databases
(`--all-databases` for MySQL; `pg_dumpall` for PostgreSQL).

The `ssb.backup-db-username` and `ssb.backup-db-password` labels apply to both
MySQL/MariaDB and PostgreSQL containers.

### Compose / Stack example

```yaml
services:
  mariadb:
    image: mariadb:11
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
    labels:
      ssb.backup-db: "mysql"
      ssb.backup-db-username: "MYSQL_ROOT_USER"
      ssb.backup-db-password: "MYSQL_ROOT_PASSWORD"
      # ssb.backup-db-names: "app_db"   # optional
    secrets:
      - db_root_password

  postgres:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
    labels:
      ssb.backup-db: "postgresql"
      # ssb.backup-db-username: "POSTGRES_USER"
      # ssb.backup-db-password: "POSTGRES_PASSWORD"
    secrets:
      - pg_password
```

---

## Credential Handling

### MySQL / MariaDB

The script reads credentials from the container's environment variables.
Priority order:

1. `ssb.backup-db-username` / `ssb.backup-db-password` label overrides (env var names)
2. `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD` → user `root`
3. `MYSQL_PASSWORD` / `MARIADB_PASSWORD` + `MYSQL_USER` / `MARIADB_USER`

**Recommended for production:** store the password in a Docker Secret and
reference it with `MYSQL_ROOT_PASSWORD_FILE`.  The official MariaDB/MySQL
images load `*_FILE` variables automatically.

### PostgreSQL

The script reads `POSTGRES_USER` (defaults to `postgres`) and
`POSTGRES_PASSWORD` from the container's environment.  The password is passed
to `pg_dump` / `pg_dumpall` via the `PGPASSWORD` environment variable on
`docker exec`.

(You can override both env var names per container with container labels)

**Recommended for production:** use Docker Secrets with `POSTGRES_PASSWORD_FILE`
or configure `pg_hba.conf` for local trust/peer authentication.

---

## Output Structure

```
/mnt/nas01backup/
  <hostname>/
    <YYYY-MM-DD>/
      backup.log              ← Full run log
      docker/                 ← Mirror of /srv/docker
        service-a/
        service-b/
        ...
      databases/
        <container-name>/
          mydb.sql.gz         ← MySQL: single database dump (gzipped)
          all-databases.sql.gz← MySQL: all-databases dump (gzipped)
          pg_dumpall.sql.gz   ← PostgreSQL: full cluster dump (gzipped)
          mydb.dump.gz        ← PostgreSQL: single database (custom format, gzipped)
    backup-YYYY-MM-DD.lock    ← Present only while the script is running

  gluster01/                  ← GlusterFS (written by the designated node only)
    <YYYY-MM-DD>/
      ...
```

---

## Dry Run

```bash
/usr/local/sbin/ssb.sh --dry-run
```

Prints every action that *would* be taken without creating directories,
writing files, running dumps, or deleting old backups.

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All backup tasks completed successfully |
| `1` | One or more tasks failed (check `backup.log`) |
| `2` | Invalid command-line arguments |

---

## Crontab Example

```cron
# Run SSB every night at 02:00, append script output to /var/log/ssb.log
0 2 * * * /usr/local/sbin/ssb.sh >> /var/log/ssb.log 2>&1
```

---

## Requirements

- Bash 4.0+
- `docker` CLI (connected to the local Docker Engine)
- `rsync`
- `curl` (only if `HEALTHCHECK_URL` is set)
- `jq` (for JSON config parsing)
- `gzip` (for compressed database backup files)
- NFS (or equivalent) mount available at `BACKUP_BASE`

---

### Retention Policy

Retention applies to both per-host backup directories (`${BACKUP_BASE}/<hostname>`) and GlusterFS backup directories (`${BACKUP_BASE}/<GLUSTER_DEST_NAME>`). Old dated directories older than `RETENTION_DAYS` are automatically removed:

- Per-host retention runs on every node.
- GlusterFS retention runs **only** on the node where `BACKUP_GLUSTER="true"`.

This ensures that both regular and GlusterFS backups are cleaned up according to your retention policy, but only one node manages GlusterFS cleanup to avoid race conditions.
