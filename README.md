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
  - MongoDB (`mongodump`)
  - SQLite3 (`sqlite3 .dump`)
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
# 1. Chmod the script
sudo chmod +x ./ssb.sh

# 2. Create a local JSON config file next to the script
sudo cp ssb.json.example ssb.json
sudo nano ssb.json

# 3. Test with --dry-run (uses ./ssb.json by default)
/path/to/script/ssb.sh --config /path/to/config/ssb.json --dry-run

# 4. Add to root crontab (runs at 02:00 every night)
echo "0 2 * * * /path/to/script/ssb.sh --config /path/to/config/ssb.json >> /var/log/ssb.log 2>&1" \
  | sudo crontab -
```

---

## Configuration

`ssb.sh` loads JSON configuration from `./ssb.json` by default.

- Optional config file via `--config <path>` (absolute path or relative path)
- Define multiple servers in one JSON file under `servers`
- The script selects config by hostname (`hostname -s`; fallback to full hostname)

Local config files are ignored by git via `.gitignore`, so they are not
affected by pull/push.

### Example

```bash
# Uses ./ssb.json in current directory
./ssb.sh --dry-run

# Uses ./ssb.prod.json (relative path)
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
    },
    "docker02": {
      "docker_exclude_dirs": [
        "service-x/tmp",
        "service-y/tmp"
      ]
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
| `healthcheck_url` | `""` | Base URL for healthcheck pings (e.g. `https://hc-ping.com/<uuid>`) |
| `healthcheck_url_start_keyword` | `""` | Optional keyword sent in request body for start pings; if empty, no start ping is sent |
| `healthcheck_url_success_keyword` | `""` | Optional keyword sent in request body for success pings; if empty, success pings use base `healthcheck_url` with no body |
| `healthcheck_url_failure_keyword` | `""` | Optional keyword sent in request body for failure pings; if empty, no failure ping is sent |
| `docker_src` | `/srv/docker` | Docker volume source directory |
| `docker_exclude_dirs` | `[]` | Paths relative to `docker_src` to exclude from rsync (merged: default + server list) |
| `backup_gluster` | `false` | Set to `true` on the one node responsible for GlusterFS |
| `gluster_dest_name` | `"gluster01"` | Output folder name under `backup_base` for GlusterFS |
| `gluster_src` | `/mnt/gluster01` | GlusterFS source directory |
| `gluster_exclude_dirs` | `[]` | Paths relative to `gluster_src` to exclude from rsync |

### Configuration

The `ssb.json` configuration file supports the following parameters:

- `exclude`: A list of unwanted files and folders to exclude from backups. Default values include:
  - `@eaDir`
  - `.DS_Store`
  - `.DS_Store@SynoResource`
  - `Thumbs.db`
  - `desktop.ini`
  - `._*`
  - `Icon\r`
  - `__MACOSX`

Ensure that the `exclude` parameter is properly defined in your `ssb.json` file to avoid backing up unnecessary files.

Healthcheck behavior:

- Success: always sends a ping when `healthcheck_url` is set (backward compatible).
- Start: sends a ping only when `healthcheck_url_start_keyword` is configured.
- Failure: sends a ping only when `healthcheck_url_failure_keyword` is configured.
- For keyword-based pings, the script calls `healthcheck_url` and sends the keyword in the request body.

---

## Container Labels

Add labels to your Docker containers or Swarm service definitions to enable
database backups.

| Label | Value | Effect |
|---|---|---|
| `ssb.backup-db` | `mysql` or `mariadb` | Dump MySQL / MariaDB databases |
| `ssb.backup-db` | `postgresql` or `postgres` | Dump PostgreSQL databases |
| `ssb.backup-db` | `mongodb` or `mongo` | Dump MongoDB databases |
| `ssb.backup-db` | `sqlite3` or `sqlite` | Dump a SQLite database file |
| `ssb.backup-db-path` | `/path/in/container/app.db` | Path to SQLite database file inside container (required for sqlite3) |
| `ssb.backup-db-names` | `db1,db2` | Specific databases to dump (optional) |
| `ssb.backup-db-username` | `ENV_VAR_NAME` | Env var name inside container for DB username (optional override) |
| `ssb.backup-db-password` | `ENV_VAR_NAME` | Env var name inside container for DB password (optional override) |
| `ssb.backup-db-auth-db` | `admin` | MongoDB authentication database (optional, default `admin`) |

Without `ssb.backup-db-names` the script performs a full dump of all databases
(`--all-databases` for MySQL; `pg_dumpall` for PostgreSQL; full `mongodump` for MongoDB).

The `ssb.backup-db-username` and `ssb.backup-db-password` labels apply to both
MySQL/MariaDB, PostgreSQL, and MongoDB containers.

For SQLite containers, set `ssb.backup-db-path` to the database file inside the
container.

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

  mongodb:
    image: mongo:7
    environment:
      MONGO_INITDB_ROOT_USERNAME: root
      MONGO_INITDB_ROOT_PASSWORD_FILE: /run/secrets/mongo_root_password
    labels:
      ssb.backup-db: "mongodb"
      # ssb.backup-db-names: "appdb" # optional
      # ssb.backup-db-auth-db: "admin" # optional
    secrets:
      - mongo_root_password

  app-with-sqlite:
    image: your-app:latest
    labels:
      ssb.backup-db: "sqlite3"
      ssb.backup-db-path: "/data/app.db"
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

### MongoDB

The script uses `mongodump` inside the container.

Credential discovery order:

1. `ssb.backup-db-username` / `ssb.backup-db-password` label overrides (env var names)
2. `MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD`
3. `MONGO_USERNAME` / `MONGO_PASSWORD`

Optional label:

- `ssb.backup-db-auth-db` (defaults to `admin`)

With `ssb.backup-db-names`, each listed database is dumped separately.
Without it, a full `mongodump` archive is created.

### SQLite3

For SQLite backups, set:

- `ssb.backup-db=sqlite3` (or `sqlite`)
- `ssb.backup-db-path=/path/to/database.sqlite` (inside the container)

The script runs `sqlite3 <path> .dump` via `docker exec`, then compresses the
result to `.sql.gz`.

If `sqlite3` is not available inside the container, SSB falls back to copying
the SQLite file to the host with `docker cp` and runs host `sqlite3` for the
dump.

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
          all-databases.archive.gz ← MongoDB: full dump archive (gzipped)
          appdb.archive.gz    ← MongoDB: single database dump archive (gzipped)
          app.sql.gz          ← SQLite3: sqlite3 .dump output (gzipped)
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
- `mongodump` CLI in MongoDB containers (only if using `ssb.backup-db=mongodb`)
- `sqlite3` CLI in SQLite containers, or on the host for fallback (only if using `ssb.backup-db=sqlite3`)
- NFS (or equivalent) mount available at `BACKUP_BASE`

---

### Retention Policy

Retention applies to both per-host backup directories (`${BACKUP_BASE}/<hostname>`) and GlusterFS backup directories (`${BACKUP_BASE}/<GLUSTER_DEST_NAME>`). Old dated directories older than `RETENTION_DAYS` are automatically removed:

- Per-host retention runs on every node.
- GlusterFS retention runs **only** on the node where `BACKUP_GLUSTER="true"`.

This ensures that both regular and GlusterFS backups are cleaned up according to your retention policy, but only one node manages GlusterFS cleanup to avoid race conditions.
