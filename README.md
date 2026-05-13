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
- **Label-driven** — opt containers in with a single Docker label
- **GlusterFS backup** — optional, enabled on exactly one node
- **Retention** — automatically removes dated backup directories older than N days
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

# 2. Edit the CONFIGURATION block at the top of the script
sudo nano /usr/local/sbin/ssb.sh

# 3. Test with --dry-run
/usr/local/sbin/ssb.sh --dry-run

# 4. Add to root crontab (runs at 02:00 every night)
echo "0 2 * * * /usr/local/sbin/ssb.sh >> /var/log/ssb.log 2>&1" \
  | sudo crontab -
```

---

## Configuration

All configurable values live at the top of `ssb.sh`.

| Variable | Default | Description |
|---|---|---|
| `BACKUP_BASE` | `/mnt/nas01backup` | Root of the NFS backup target |
| `DOCKER_SRC` | `/srv/docker` | Docker volume source directory |
| `GLUSTER_SRC` | `/mnt/gluster01` | GlusterFS source directory |
| `BACKUP_GLUSTER` | `"false"` | Set to `"true"` on the one node responsible for GlusterFS |
| `GLUSTER_DEST_NAME` | `"gluster01"` | Output folder name under `BACKUP_BASE` for GlusterFS |
| `RETENTION_DAYS` | `5` | Days to keep per-host dated directories |
| `EXISTING_BACKUP_ACTION` | `"overwrite"` | `"overwrite"` or `"keep"` when today's backup already exists |
| `DOCKER_EXCLUDE_DIRS` | `()` | Paths relative to `DOCKER_SRC` to exclude from rsync |
| `HEALTHCHECK_URL` | `""` | URL to curl on success (e.g. `https://hc-ping.com/<uuid>`) |

---

## Container Labels

Add labels to your Docker containers or Swarm service definitions to enable
database backups.

| Label | Value | Effect |
|---|---|---|
| `ssb.backup-db` | `mysql` or `mariadb` | Dump MySQL / MariaDB databases |
| `ssb.backup-db` | `postgresql` or `postgres` | Dump PostgreSQL databases |
| `ssb.backup-db-names` | `db1,db2` | Specific databases to dump (optional) |

Without `ssb.backup-db-names` the script performs a full dump of all databases
(`--all-databases` for MySQL; `pg_dumpall` for PostgreSQL).

### Compose / Stack example

```yaml
services:
  mariadb:
    image: mariadb:11
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
    labels:
      ssb.backup-db: "mysql"
      # ssb.backup-db-names: "app_db"   # optional
    secrets:
      - db_root_password

  postgres:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
    labels:
      ssb.backup-db: "postgresql"
    secrets:
      - pg_password
```

---

## Credential Handling

### MySQL / MariaDB

The script reads credentials from the container's environment variables.
Priority order:

1. `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD` → user `root`
2. `MYSQL_PASSWORD` / `MARIADB_PASSWORD` + `MYSQL_USER` / `MARIADB_USER`

**Recommended for production:** store the password in a Docker Secret and
reference it with `MYSQL_ROOT_PASSWORD_FILE`.  The official MariaDB/MySQL
images load `*_FILE` variables automatically.

### PostgreSQL

The script reads `POSTGRES_USER` (defaults to `postgres`) and
`POSTGRES_PASSWORD` from the container's environment.  The password is passed
to `pg_dump` / `pg_dumpall` via the `PGPASSWORD` environment variable on
`docker exec`.

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
          all-databases.sql   ← MySQL: all-databases dump
          mydb.sql            ← MySQL: single database dump
          pg_dumpall.sql      ← PostgreSQL: full cluster dump
          mydb.dump           ← PostgreSQL: single database (custom format)
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
- NFS (or equivalent) mount available at `BACKUP_BASE`
