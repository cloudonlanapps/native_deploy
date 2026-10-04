# native_deploy

Runs `club_server` natively on a developer machine, outside Docker, for the
integration test suites of every consumer (`club_sdk_2`, the CLI, the apps)
and for day-to-day development. Same shape as `deploy_servers`: one
conf per stack, one command, everything the stack owns under `deployed/`.
Deploying to a host is `deploy_servers`; this repo never touches one.

## Three layers

| Layer | Script | Runs |
|---|---|---|
| 1 | `background_server.sh <conf> start\|stop\|cleanup\|status\|logs\|backup\|restore` | layer 2 in a detached tmux session; waits for `/health`; prints the stack as JSON |
| 2 | `start_server.sh <conf> [port=N db_port=N] [--source DIR\|URL]` | layer 3 in the terminal, with everything exported from the conf |
| 3 | `run_server.sh` | the server from the environment alone: cluster, `uv sync`, `alembic upgrade head`, `club_bootstrap`, `uvicorn`. Fatal if any variable is missing |

## Backup and restore

```bash
background_server.sh <conf> backup  [port=N db_port=N] [--out DIR] [--name NAME]
background_server.sh <conf> restore [port=N db_port=N] [stamp] [--list] [--dry-run]
```

Both take the same conf and the same `port=` / `db_port=` overrides as every
other verb, so they address the run you actually started. `backup_server.sh`
and `restore_server.sh` are callable directly too.

**Backup runs where the server is.** It reads only — the stack keeps serving —
and writes:

```
<out>/<name>-<UTC stamp>.tar.gz   pg_dump -Ft --no-owner --no-privileges, gzipped
<out>/files/uploads/              verbatim
<out>/files/static/               verbatim
<out>/MANIFEST.txt                source, schema revision, row counts, sizes
```

**Restore reads `backup/` beside the scripts and nothing else.** It does not
contact a backup host and needs no credentials for one: a restore target is
often the public-facing machine, and giving it reach into the backup store is
the wrong trade. Copying an archive there is a separate job — an rsync from the
backup side, or a person with a USB stick. `--list` says so when the directory
is empty.

Restore is destructive: the database is dropped and recreated, and the upload
and static trees are replaced. `--dry-run` resolves everything and touches
nothing. It refuses when the archive's alembic revision does not match the
running code — deploy the matching code rather than forcing it.

The format is deliberately the one `server_hosting_scripts/restore-backup.sh`
reads, so an archive taken from a native stack restores into a Docker
deployment and the other way round. That is why the dump is tar format gzipped
rather than custom format: restore does `gzip -dc` into a tar and hands it to
`pg_restore`.

`uploads/media/_pending/` is not backed up. It stages a video for the
conversion worker — work in progress, not data — and the server recreates it.

## Stopping and cleaning up

`stop_server.sh <conf> [port=N db_port=N] [--remove]` stops a layer-2 run's
cluster and any uvicorn still on its port; `--remove` (layer 1: `cleanup`)
deletes the run's directory. `start_db.sh` is the cluster script, carried
here so the repo is self-contained. All four are bash and work from any
directory: put this directory on `PATH` and call them from a consumer repo.

## Confs

Read like `deploy_servers`' `product.conf`:

```ini
[product]   source                  # a checkout (relative to the conf file, run in place)
                                    # or a git URL (cloned at `ref` into the run directory)
            ref                     # git sources only; default main
[server]    port, db_port, debug, bootstrap_password, secret_key
[settings]  any server setting, exported as its upper-case name; <port> = the server port
```

Only two templates live here, `sample.conf` (all three modules on,
identity verification on) and
`sample_debug.conf` (`uvicorn --reload`, refused by layer 1). Each
consumer keeps its own confs in its own repo; a throwaway conf anywhere on
disk works too. The values are fixed test values, not secrets, never for a
deployment.

## Where a run lives

A run is named after the conf's absolute path with `/` replaced by `__` (so
two confs of one name in two repos never collide), plus `_<port>_<db_port>`
when the ports are overridden. It owns `deployed/<name>/` here: `src/` (the
clone, only when no source checkout was named), `data/` (cluster, uploads,
static) and `server.log`. The tmux session carries the same name, so `stop`
and `cleanup` need only the conf and the same overrides. A checkout named as
the source is used in place and never deleted; `--source` on the command line
replaces the conf's value with either form. `deployed/` is git-ignored.

Only the two ports can be overridden. Two runs of one conf need different
ports; `background_server … start --auto-ports` picks free ones, which is how
test suites run concurrently.

## Examples

```bash
# a stack for a test suite: free ports, the conf's source checkout, torn down after
json=$(background_server.sh sdk.conf start --auto-ports)
base=$(jq -r .base_url <<<"$json")
background_server.sh sdk.conf cleanup port=… db_port=…

# a fixed-port server cloned from git at the conf's ref
background_server.sh cli.conf start
background_server.sh cli.conf logs
background_server.sh cli.conf stop

# development, in the terminal, reloading on edit
start_server.sh debug.conf --source ../club_server
```

Prerequisites: `uv`, `tmux`, `ss`, and PostgreSQL binaries `start_db.sh` can
find (`PATH`, Homebrew `postgresql@16`, or `/usr/lib/postgresql/<v>/bin`).
The sample confs clone the public `cloudonlanapps/club_server` over https, so
no key is needed.
