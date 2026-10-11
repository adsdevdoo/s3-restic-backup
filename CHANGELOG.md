# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new major version means a change you have to act
on (settings, data layout, metric names).

## [Unreleased]

### Fixed
- Grafana dashboard: the stats at the top show the current value. Over the 7-day range they stepped ~30 minutes
  and showed "No data" for metrics younger than a step (a new source, the first runs).

## [1.0.0] - 2026-10-11

First release.

### Added
- Any number of S3 sources (`SOURCES`), any S3-compatible provider, each with its own bucket, prefix, endpoint,
  keys, schedule, retention and rclone flags.
- One-way `rclone copy` of each bucket into a local copy (objects deleted in the bucket stay) and a listing of the
  bucket kept with every snapshot.
- One restic repository for all sources: snapshots tagged by source, per-source retention, prune once a day,
  weekly `restic check`.
- Keys passed to rclone only through its environment and masked in everything rclone logs; `--dump`,
  `--log-file` and `--s3-sdk-log-mode` refused.
- Optional off-host copy of the repository with rsync over SSH (`COPY_TARGET`).
- Metrics for the node_exporter textfile collector, per source; Grafana dashboard in `grafana/`.
- Offline tests (`tests/test.sh`) against a stub rclone and against `rclone serve s3`; images for amd64 and arm64
  on ghcr.io.

[Unreleased]: https://github.com/adsdevdoo/s3-restic-backup/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/adsdevdoo/s3-restic-backup/releases/tag/v1.0.0
