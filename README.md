# s3-restic-backup

[![build](https://github.com/adsdevdoo/s3-restic-backup/actions/workflows/build.yml/badge.svg)](https://github.com/adsdevdoo/s3-restic-backup/actions/workflows/build.yml)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-adsdevdoo%2Fs3--restic--backup-blue?logo=github)](https://github.com/adsdevdoo/s3-restic-backup/pkgs/container/s3-restic-backup)
[![Docker Hub](https://img.shields.io/docker/v/adsdevdoo/s3-restic-backup?sort=semver&logo=docker&label=docker%20hub)](https://hub.docker.com/r/adsdevdoo/s3-restic-backup)
[![Docker pulls](https://img.shields.io/docker/pulls/adsdevdoo/s3-restic-backup?logo=docker)](https://hub.docker.com/r/adsdevdoo/s3-restic-backup)
[![image size](https://img.shields.io/docker/image-size/adsdevdoo/s3-restic-backup/latest?logo=docker)](https://hub.docker.com/r/adsdevdoo/s3-restic-backup)
![platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey)
[![release](https://img.shields.io/github/v/release/adsdevdoo/s3-restic-backup?sort=semver)](https://github.com/adsdevdoo/s3-restic-backup/releases)
[![license](https://img.shields.io/github/license/adsdevdoo/s3-restic-backup)](LICENSE)
[![last commit](https://img.shields.io/github/last-commit/adsdevdoo/s3-restic-backup)](https://github.com/adsdevdoo/s3-restic-backup/commits/main)

Scheduled backup of any number of S3 buckets, from any S3-compatible provider, into one restic repository, in a
single Docker container.

[rclone](https://rclone.org/) copies each bucket into a local directory, and [restic](https://restic.net/)
snapshots it. Optionally, the restic repository is copied to a second host over SSH. The copy is one-way: nothing
is ever written to a bucket and nothing is deleted locally, so an object deleted in the bucket stays in the backup.
Each bucket (a *source*) has its own schedule and retention; all of them share one repository, so the same file
in two buckets (say, production and staging) is stored once.

restic can't read from S3, only store into it, hence the local copy. It costs disk space equal to the buckets, and
saves traffic: each run downloads only new and changed objects.

## Features

- **One-way, nothing lost.** The buckets are only read; objects deleted or overwritten in a bucket stay in the
  snapshots.
- **Any number of buckets, any S3.** AWS, Selectel, MinIO, Ceph, Wasabi…: each source with its own endpoint, keys,
  schedule and retention.
- **Snapshots, not a mirror.** restic keeps hourly, daily, weekly and monthly snapshots, deduplicated across all
  buckets and encrypted. Each snapshot keeps the bucket listing of its time.
- **Cheap runs.** Only new and changed objects are downloaded, compared by the listing, without a request per
  object.
- **Keys stay secret.** Never on a command line, masked in rclone's logs; flags that would print them are refused.
- **Off-host copy** to a second machine over SSH, with a key that can only add files (rrsync).
- **Metrics and a Grafana dashboard** per source.
- **One container**, amd64 and arm64, settings in `.env`.

## Quick start

```sh
git clone https://github.com/adsdevdoo/s3-restic-backup.git && cd s3-restic-backup
cp .env.example .env                 # DATA_DIR, SOURCES and <NAME>_BUCKET, <NAME>_ENDPOINT per source
mkdir -p secrets && chmod 700 secrets
read -rs k && printf '%s' "$k" > secrets/prod_access_key; unset k     # per source: access key…
read -rs k && printf '%s' "$k" > secrets/prod_secret_key; unset k     # …and secret key
head -c 32 /dev/urandom | base64 > secrets/restic_password && chmod 600 secrets/*
mkdir -p /srv/s3-backup              # the DATA_DIR from .env
docker compose pull && docker compose up -d && docker exec s3-backup backup.sh init
```

The first backup then runs on the schedule (04:30); to start it now, see [Install](#install). Details, and what
to save in your password manager, are there too. A read-only key for Selectel, step by step (in Russian):
[docs/selectel.md](docs/selectel.md).

## What a run of a source does

1. **Copy.** `rclone copy` downloads the objects that are new or changed since the last run into
   `DATA_DIR/mirror/<source>`. An object counts as changed when its size differs or its LastModified is newer than
   the local file's; rclone takes LastModified from the bucket listing, so a run costs a few list requests, not one
   request per object. Then rclone lists the bucket into `DATA_DIR/state/<source>/listing.tsv` (time, size, path):
   what the bucket held at that time.
2. **Snapshot.** restic snapshots the copy and the listing into `DATA_DIR/restic`, tagged with the source name.
   Retention, by default: 30 daily, 8 weekly, 24 monthly. Once a day `restic prune` removes the data no snapshot
   needs any more; once a week `restic check` reads 10% of the data. If the copy failed, the snapshot is still
   taken, but retention is skipped and the run counts as failed.
3. **Copy off-host** (optional). rsync sends the repository files the second host doesn't have yet.

The scheduler (supercronic) runs each source on its own schedule, daily at 04:30 by default. Two runs of the same
source never overlap; runs of different sources copy at the same time and take turns with the repository.

## Image tags

Images for `linux/amd64` and `linux/arm64`, the same in both registries:

- `ghcr.io/adsdevdoo/s3-restic-backup`
- [`adsdevdoo/s3-restic-backup`](https://hub.docker.com/r/adsdevdoo/s3-restic-backup) (Docker Hub)

| Tag | What it is | Use it when |
|---|---|---|
| `latest` | the newest release | you want releases, no pinning |
| `1`, `1.2`, `1.2.3` | the newest `1.x.x`, the newest `1.2.x`, exactly `1.2.3` | `1`: updates without breaking changes; `1.2.3`: nothing changes until you decide |
| `edge` | the current `main`, not released yet | trying what's coming |
| `sha-abc1234`, full commit SHA | one exact commit | pinning a deployment to a commit |

`compose.yml` runs `latest`; set `IMAGE` in `.env` to pick another tag, or your own build
(`docker build -t s3-restic-backup:local .`, then `IMAGE=s3-restic-backup:local`).

Versions follow [Semantic Versioning](https://semver.org/): a new major version means something you have to act on
(settings, data layout, metric names). Changes are listed in [CHANGELOG.md](CHANGELOG.md) and on the
[releases page](https://github.com/adsdevdoo/s3-restic-backup/releases).

## Install

You need Docker with Compose, a directory for the data, and per bucket an access key that can list and read it.
A read-only key is best: the backup never writes to a bucket, and a key that can't won't either.

```sh
git clone https://github.com/adsdevdoo/s3-restic-backup.git
cd s3-restic-backup
cp .env.example .env               # set DATA_DIR, SOURCES and the settings of each source
mkdir -p secrets && chmod 700 secrets
# For each source <name> in SOURCES, two files: type the key, Enter.
read -rs k && printf '%s' "$k" > secrets/prod_access_key; unset k
read -rs k && printf '%s' "$k" > secrets/prod_secret_key; unset k
head -c 32 /dev/urandom | base64 > secrets/restic_password
chmod 600 secrets/*
mkdir -p /srv/s3-backup            # the DATA_DIR from .env
docker compose up -d
docker exec s3-backup backup.sh init
```

**Save `secrets/restic_password` in your password manager.** Without it the snapshots can't be opened.

The container checks the settings and the key files when it starts and stops if something is wrong:
`docker logs s3-backup` says what. To run every source now instead of waiting for the schedule, detached from your
shell, with the output going to `docker logs`:

```sh
docker exec -d s3-backup sh -c 'backup.sh >/proc/1/fd/1 2>&1'
docker logs -f s3-backup
```

A run of a source ends with `[<source>] done: bucket N objects …`. `backup.sh run prod` runs one source.

The data directory must exist before `up`. Compose won't create it, so that a backup never lands on the root disk
when the backup disk isn't mounted. For the same reason a run never creates the repository; only `init` does.

## Settings

All settings are in `.env`; see `.env.example`.

| Variable | Default | |
|---|---|---|
| `DATA_DIR` | — | host directory for the copies, the repository and the state |
| `SOURCES` | — | source names, space-separated: lower-case letters, digits, `_` |
| `SCHEDULE`, `TZ` | `30 4 * * *`, UTC | default schedule, time zone of all schedules |
| `KEEP_HOURLY`, `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY` | 0, 30, 8, 24 | default snapshot retention |
| `CHECK_WEEKDAY`, `CHECK_READ_SUBSET` | 7, 10% | weekly `restic check` (1 = Monday; empty = never) |
| `RCLONE_FLAGS` | — | extra rclone flags, e.g. `--bwlimit 10M --tpslimit 10` |
| `COPY_TARGET`, `COPY_PORT` | off, 22 | off-host copy, `user@host:path`; the colon is required |
| `COPY_KEY_FILE`, `COPY_KNOWN_HOSTS_FILE` | `/run/secrets/copy_ssh_key`, `…/copy_known_hosts` | SSH key and host key of the off-host copy |
| `SNAPSHOT_HOST` | `s3-backup` | host name of the snapshots; retention only touches snapshots with this one, so don't change it later |
| `WAIT_FOR_LOCK` | `no` | `yes`: a run waits for a running run of the same source instead of skipping (for manual loops) |

Per source `<name>`, the settings are `<NAME>_…`, the name in upper case (`prod` → `PROD_BUCKET`):

| Variable | Default | |
|---|---|---|
| `<NAME>_BUCKET` | — | bucket name |
| `<NAME>_PREFIX` | whole bucket | only this path in the bucket |
| `<NAME>_ENDPOINT` | AWS | S3 endpoint URL |
| `<NAME>_REGION` | provider default | region |
| `<NAME>_PROVIDER` | `Other` | rclone S3 provider: `AWS`, `Ceph`, `Minio`, `Wasabi`, … (`Other` works for most) |
| `<NAME>_PATH_STYLE` | `yes` | `yes`: `https://endpoint/bucket` URLs; `no`: `https://bucket.endpoint` |
| `<NAME>_SCHEDULE` | `SCHEDULE` | cron schedule of this source |
| `<NAME>_KEEP_HOURLY` … `_KEEP_MONTHLY` | `KEEP_*` | retention of this source |
| `<NAME>_RCLONE_FLAGS` | `RCLONE_FLAGS` | extra rclone flags of this source |

Keys: `secrets/<name>_access_key` and `secrets/<name>_secret_key`. rclone gets them in its environment, never on a
command line. With `-vv` rclone logs the options it reads from the environment, the keys included; the script
replaces the key values with `***` in everything rclone logs, plain or JSON (`--use-json-log`). `--dump`,
`--log-file` and `--s3-sdk-log-mode` are refused: they would print the keys or the requests past the mask.
`RCLONE_*` variables in `.env` don't reach rclone; put flags in `RCLONE_FLAGS`.

The rclone flags apply to the listing too: a filter (`--include`, `--max-age`, …) narrows both the copy and
`listing.tsv`, and the bucket metrics count only what passes it.

Retention applies to the snapshots of one source; a schedule more often than daily keeps one snapshot a day unless
`KEEP_HOURLY` is set. After changing `.env`, run `docker compose up -d`. To update to the latest image:
`docker compose pull && docker compose up -d` (not during a run: `docker logs` shows when one ends).

## Restore

```sh
docker exec s3-backup restic snapshots --tag prod
docker exec s3-backup restic restore latest --tag prod --target /data/restore
docker exec s3-backup restic restore latest --tag prod --target /data/restore --include /data/mirror/prod/images
```

The result lands in `DATA_DIR/restore/data/mirror/prod/`; the files are root-only (600). Push them back with rclone,
for example `rclone copy DATA_DIR/restore/data/mirror/prod remote:bucket`, with a key that can write.

The copy keeps objects deleted in the bucket. To restore the bucket as it was at the time of a snapshot, take only
the paths in that snapshot's `state/<source>/listing.tsv` (third column):

```sh
cut -f3- DATA_DIR/restore/data/state/prod/listing.tsv > files.txt
rclone copy --files-from-raw files.txt DATA_DIR/restore/data/mirror/prod remote:bucket
```

rclone writes a name with control characters (a tab, a newline) differently in the listing and on disk; such
objects are skipped by `--files-from-raw` and need copying by hand.

To restore from the off-host copy: get the directory to any machine with restic and run
`restic -r <dir> restore latest --tag prod --target …` with the same password.

## Off-host copy

Set `COPY_TARGET` and put an SSH key in `secrets/copy_ssh_key` and the target's host key in
`secrets/copy_known_hosts`:

```sh
ssh-keygen -t ed25519 -N '' -f secrets/copy_ssh_key
ssh-keyscan -p 22 -t ed25519 backup-host.example > secrets/copy_known_hosts    # same port as COPY_PORT
ssh-keygen -lf secrets/copy_known_hosts     # compare with the fingerprint shown on the target
```

With the rrsync line below, use an empty path: `COPY_TARGET=backup@backup-host.example:`. The files then land
right in the rrsync directory.

On the target, restrict the key to adding files in one directory, with `rrsync` from the rsync package:

```
restrict,from="10.0.0.5",command="/usr/bin/rrsync -wo -no-del -no-overwrite -munge /srv/s3-backup-copy" ssh-ed25519 AAAA… s3-backup
```

- `-munge` is what keeps the key inside the directory: without it a compromised backup host can upload a symbolic
  link and write through it outside the directory, e.g. into the user's `~/.ssh`, and get a shell on the target
  (rsync older than 3.5 lets it). Keep it.
- `-no-del` blocks deletion, `-no-overwrite` overwriting a file that is there. `-no-overwrite` needs rsync 3.3 or
  newer on the target; with an older one (Debian 12, Ubuntu 24.04) use `-wo -no-del -munge`, and protect the
  received files with `chattr +i` if a compromised backup host must not be able to spoil the copy.

Repository files never change once written, so adding the new ones keeps the copy a valid restic repository. It is
a superset: snapshots pruned locally stay there. Nothing prunes the copy, so pick the snapshot by date when you
restore from it.

A failed copy doesn't fail the run. It has its own metric (below).

## Metrics

Mount a node_exporter textfile collector directory at `/metrics` (see `compose.yml`) to get, per source (label
`source`):

| Metric | |
|---|---|
| `s3_backup_last_success_timestamp_seconds` | last good run |
| `s3_backup_last_failure_timestamp_seconds` | last failed run |
| `s3_backup_last_duration_seconds` | how long the last good run took |
| `s3_backup_bucket_objects`, `s3_backup_bucket_bytes` | what the bucket held at the last good run |
| `s3_backup_mirror_files`, `s3_backup_mirror_bytes` | the local copy, objects deleted in the bucket included |

and for the whole repository `s3_backup_repository_bytes`, `s3_backup_copy_last_success_timestamp_seconds`,
`s3_backup_copy_last_failure_timestamp_seconds`.

The metrics of a source are in `s3_backup_source.<source>.success.prom` and `….failure.prom`. When you remove a
source from `SOURCES`, delete its two files, or it stays on dashboards and in alerts with an ever older last run.

Useful alerts:
- no success for longer than the schedule plus a margin: `time() - s3_backup_last_success_timestamp_seconds > 26*3600`
  for daily sources (set the limit per source if the schedules differ);
- the last run failed: failure newer than success;
- a bucket emptied or shrank by a lot: `s3_backup_bucket_objects` fell by more than 10% over a day. The backup
  keeps the deleted objects; the alert is about the bucket.

## Files

| | |
|---|---|
| `backup.sh` | everything a run does; the comments at the top explain the less obvious parts |
| `entrypoint.sh` | checks the settings, writes the crontab (a line per source) and starts supercronic |
| `Dockerfile` | Alpine with rclone, restic, supercronic, rsync |
| `.github/workflows/build.yml` | tests on every push; images for amd64 and arm64 on `main` and on release tags; GitHub Releases from `CHANGELOG.md` |
| `CHANGELOG.md` | what changed in each release |
| `docs/selectel.md` | a read-only key for Selectel S3, step by step (in Russian) |
| `compose.yml`, `.env.example` | how to run it |
| `tests/test.sh` | tests against a stub rclone and against `rclone serve s3`, no bucket needed: `sh tests/test.sh` (Docker; the first build downloads Alpine packages) |
| `grafana/s3-backup.json` | Grafana dashboard: a table of the sources, repository, off-host copy, trends; pick the Prometheus data source in the dropdown at the top |
| `CLAUDE.md` | rules for changing the code |

Inside `DATA_DIR`:

| | |
|---|---|
| `mirror/<source>/` | the copy of each bucket |
| `state/<source>/listing.tsv` | the last listing of the bucket; in every snapshot of the source |
| `restic/` | the repository |
| `cache/` | restic's cache |

## License

MIT
