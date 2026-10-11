# Working on s3-restic-backup

Rules for anyone changing this repository, Claude included. This is a public repository: never commit anything
about a particular deployment (hosts, IPs, user names, bucket names, endpoints, paths of a real server, keys).

## Changes, commits, pushes

- No commit, push or tag without an explicit OK from the maintainer ("commit", "push"). Changes stay in the
  working tree until then. Commits already made are not rolled back; later work goes on top of them.
- Never rewrite pushed history (no amend, rebase or force-push of pushed commits): deployments pin an image by its
  commit, which must stay reachable.
- Commit messages in English, in the style of the history: a short subject line and a body that says why. No
  `Co-Authored-By` or any other attribution trailer.
- One fix or feature per commit, with its README changes in the same commit.
- Edit files by hand in an editor (Claude: the Edit/Write tools), one place at a time. Don't patch files with sed,
  python or heredocs: escaping breaks and the change isn't visible as a diff.
- Long commands (image builds, the test run) go to the background; don't block the session on them.

## Review before pushing

Every change gets reviewed before it is pushed, and the review is repeated after each round of fixes until a round
finds nothing. Each finding gets a severity, a concrete failure scenario and a decision: fixed, accepted (with the
reason) or left for later. Check claims against facts (logs, a test run, rclone's documentation for the version in
the image) before fixing a "could happen": hypotheses are not bugs.

## CI and images

- `.github/workflows/build.yml`: tests on every push and PR; on `main` and `v*` tags it builds amd64 and arm64 and
  pushes to `ghcr.io/adsdevdoo/s3-restic-backup` and, when the repository variable `DOCKERHUB_USERNAME` and the
  secret `DOCKERHUB_TOKEN` are set, to Docker Hub. Tags: `X.Y.Z`, `X.Y`, `X` and `latest` for a release, `edge` for
  `main`, `sha-<short>` and the full SHA for every build.
- The ghcr package of this public repository came out public on its first push (it inherits the repository's
  access). If a fork's package starts private, set it to Public once (package settings → Change visibility).
- **A release** (with the maintainer's OK): move the `[Unreleased]` items of `CHANGELOG.md` under a new
  `## [X.Y.Z] - date` heading and fix the links at the bottom, commit, then tag that commit `vX.Y.Z` and push the
  tag. CI builds the release images and creates the GitHub Release from that CHANGELOG section (it fails if the
  section is missing). SemVer: a change users must act on (settings, data layout, metric names) is a new major.
- Every user-visible change goes into `CHANGELOG.md` under `[Unreleased]` in the same commit.

## Tests

- `sh tests/test.sh` builds the image and runs backup.sh against a stub rclone that serves "buckets" from local
  directories. The scenarios run without network (the first build needs it for the Alpine packages). All
  scenarios must pass; the script ends with `FAILED: 0`. The data directory carries over from one scenario to the
  next: order matters.
- New behavior gets a new scenario. A fix for a bug gets a scenario that failed before the fix.
- The stub accepts only `copy` and `lsf`; anything else fails the tests. The tests also fail if a key shows up in
  the output.
- The stub accepts any flag. The real rclone flags are exercised by the scenario against `rclone serve s3` running
  inside the test container (the stub is mounted at `/usr/local/bin/rclone`, ahead of the real one in PATH).
- When a change touches how the image starts (Dockerfile, entrypoint), run the image's own command, not just
  `docker run … backup.sh`.
- Don't test against a real bucket casually: requests cost money and providers rate-limit. One careful run, read
  the log, stop.

## Code

- Bash with `set -euo pipefail` and `umask 077`. Each function starts with a comment `name <args> : what it does`;
  comments explain why, not what.
- `set -e` is off inside a function called as `f || …` (and in everything it calls). Such functions check each
  step explicitly (`|| return 1`) and replace files only after every step succeeded.
- Arithmetic on settings only after the checks validated them as numbers without leading zeros.
- A source name goes into variable names, file names and metric labels: it is validated before any use
  (`^[a-z][a-z0-9_]{0,31}$`).
- **Never write to a bucket.** rclone runs only `copy` (bucket → local) and `lsf`. No `sync`, `move`, `delete`,
  `purge`, no bucket as a destination.
- **Never print a key**: not in logs, not on a command line (ps shows it), not in examples or commit messages. Keys
  go to rclone through `RCLONE_CONFIG_SRC_*` set inside a subshell. rclone with `-vv` logs them
  (`Setting secret_access_key="…" … from environment variable`, quoted with Go `%q`; with `--use-json-log` quoted
  once more). rclone_src masks them by value, in all three forms, not by a pattern: a key may hold `\` or `"`.
  `--dump`, `--log-file` and `--s3-sdk-log-mode` are refused, and no other `RCLONE_*` variable of the environment
  reaches rclone (`RCLONE_LOG_FILE` would bypass the filter).
- Versions in the image: Alpine 3.22, rclone 1.69, restic 0.18, supercronic 0.2, GNU gawk.

## What we learned about rclone (1.69)

- On S3 an object's modification time comes from its `X-Amz-Meta-Mtime` metadata, which costs a HEAD request per
  object. `--use-server-modtime` takes LastModified from the listing instead; with `--update` a changed object is
  still copied (newer LastModified), and the local file gets that LastModified as its mtime.
- `--config /dev/null` keeps the configuration in memory: the remote is defined by `RCLONE_CONFIG_SRC_*` only.
- `rclone lsf --format tsp --separator $'\t'` puts the path last, so a separator in a name does not shift the
  columns.
