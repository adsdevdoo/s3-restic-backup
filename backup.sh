#!/usr/bin/env bash
#
# s3-restic-backup: scheduled backup of S3 buckets (any S3-compatible provider) into one restic repository.
# For each source (a bucket, or a prefix in one) a run does:
#   1. rclone copies the bucket into /data/mirror/<source>: one way, only new and changed objects, nothing is ever
#      written to the bucket and nothing is deleted locally. rclone lists the bucket into
#      /data/state/<source>/listing.tsv: what the bucket held at that time.
#   2. restic takes a snapshot of the mirror and the listing into /data/restic and applies the source's retention.
#   3. Optionally the repository files are copied to another host with rsync over SSH.
# The mirror alone is not a backup: an object overwritten in the bucket is overwritten in the mirror. The snapshots
# are. An object deleted in the bucket stays in the mirror; the listing of a snapshot says whether the bucket still
# had it.
#
# Usage (inside the container):
#   backup.sh                   a run of every source in SOURCES, one after another
#   backup.sh run [source...]   a run of those sources (the scheduler runs one per crontab line)
#   backup.sh init              create the restic repository, once
#   backup.sh check             check the settings and secret files of every source (the entrypoint runs this)
#
# Settings come from the environment, see .env.example. Per source <name>: <NAME>_BUCKET and so on (the name in
# upper case); a per-source value falls back to the global one where there is one (SCHEDULE, KEEP_*, RCLONE_FLAGS).
# Keys: /run/secrets/<name>_access_key and <name>_secret_key.
#
# Locks. Each source has its own lock (/data/.lock-<source>): runs of different sources copy at the same time.
# Everything that touches the repository (snapshot, forget, prune, check, off-host copy) runs under one more lock,
# /data/.restic.lock, waited for, so restic never runs twice at once and the off-host copy never sees a half-written
# repository.
#
# Comparing objects. rclone takes the LastModified of the listing as an object's time (--use-server-modtime) and
# copies an object whose size differs or that is newer than the local file (--update); the local file gets the
# object's LastModified. Without this rclone would ask the bucket for each object's metadata on every run (one HEAD
# request per object).
#
set -euo pipefail
umask 077

# --- settings (environment) ---
# Not into SOURCES itself: bash does not export an array, and the runs of several sources start backup.sh again.
read -r -a SOURCE_LIST <<<"${SOURCES:-}"
KEEP_HOURLY="${KEEP_HOURLY:-0}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-24}"
# Extra rclone flags for every source, e.g. --bwlimit 10M or --tpslimit 10; space-separated.
RCLONE_FLAGS="${RCLONE_FLAGS:-}"
# restic check on this weekday (date +%u, 1 = Monday; empty = never), reading this share of the data.
CHECK_WEEKDAY="${CHECK_WEEKDAY-7}"
CHECK_READ_SUBSET="${CHECK_READ_SUBSET:-10%}"
SNAPSHOT_HOST="${SNAPSHOT_HOST:-s3-backup}"
# yes: wait for a running backup of the same source instead of skipping (for loops of manual runs).
WAIT_FOR_LOCK="${WAIT_FOR_LOCK:-no}"
# Off-host copy: empty COPY_TARGET = off.
COPY_TARGET="${COPY_TARGET:-}"
COPY_PORT="${COPY_PORT:-22}"
COPY_KEY="${COPY_KEY_FILE:-/run/secrets/copy_ssh_key}"
COPY_KNOWN_HOSTS="${COPY_KNOWN_HOSTS_FILE:-/run/secrets/copy_known_hosts}"
SECRETS_DIR="/run/secrets"
# RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE and RESTIC_CACHE_DIR come from the image.

# --- paths ---
MIRROR_ROOT="/data/mirror"
STATE_ROOT="/data/state"
REPO_LOCK="/data/.restic.lock"
# The day of the last prune and of the last check (date +%F), so that several runs a day do it once.
PRUNE_STAMP="/data/.last-prune"
CHECK_STAMP="/data/.last-check"
# node_exporter textfile collector; nothing is written when it is not mounted.
METRICS_DIR="/metrics"

# The source of this run and its settings, set by load_source.
SRC=""


log() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${SRC:+[$SRC] }$*"
}


# write_prom <file> : stdin -> METRICS_DIR/<file>, atomically, readable by node_exporter.
write_prom() {
    local tmp

    if [[ ! -d "$METRICS_DIR" ]]; then
        cat >/dev/null
        return 0
    fi
    tmp="$(mktemp "$METRICS_DIR/.${1%.prom}.XXXXXX")" || return 1
    cat >"$tmp" && chmod 644 "$tmp" && mv "$tmp" "$METRICS_DIR/$1" || { rm -f "$tmp"; return 1; }
}


# source_prom <success|failure> : the metric file of this source. The dots keep it apart from the files of the
# repository and of the copy, and from the files of other sources (a source x_failure must not overwrite the failure
# file of x): a source name has no dot.
source_prom() {
    printf 's3_backup_source.%s.%s.prom' "$SRC" "$1"
}


on_exit() {
    local rc=$?

    if (( rc != 0 )); then
        log "ERROR: backup failed (exit code $rc)."
        write_prom "$(source_prom failure)" <<EOF || true
# HELP s3_backup_last_failure_timestamp_seconds When the last backup run of a source failed.
# TYPE s3_backup_last_failure_timestamp_seconds gauge
s3_backup_last_failure_timestamp_seconds{source="$SRC"} $(date +%s)
EOF
    fi
}


# upper <name> : the name in upper case, the prefix of its settings.
upper() {
    printf '%s' "${1^^}"
}


# setting <name> <key> [default] : the value of <NAME>_<key>, or the default when it is unset or empty.
setting() {
    local var
    var="$(upper "$1")_$2"
    printf '%s' "${!var:-${3:-}}"
}


# load_source <name> : the settings of that source into the S_* variables.
load_source() {
    SRC="$1"
    S_BUCKET="$(setting "$1" BUCKET)"
    S_PREFIX="$(setting "$1" PREFIX)"
    S_ENDPOINT="$(setting "$1" ENDPOINT)"
    S_REGION="$(setting "$1" REGION)"
    S_PROVIDER="$(setting "$1" PROVIDER Other)"
    S_PATH_STYLE="$(setting "$1" PATH_STYLE yes)"
    S_RCLONE_FLAGS="$(setting "$1" RCLONE_FLAGS "$RCLONE_FLAGS")"
    S_KEEP_HOURLY="$(setting "$1" KEEP_HOURLY "$KEEP_HOURLY")"
    S_KEEP_DAILY="$(setting "$1" KEEP_DAILY "$KEEP_DAILY")"
    S_KEEP_WEEKLY="$(setting "$1" KEEP_WEEKLY "$KEEP_WEEKLY")"
    S_KEEP_MONTHLY="$(setting "$1" KEEP_MONTHLY "$KEEP_MONTHLY")"
    S_ACCESS_KEY_FILE="$SECRETS_DIR/${1}_access_key"
    S_SECRET_KEY_FILE="$SECRETS_DIR/${1}_secret_key"
    MIRROR="$MIRROR_ROOT/$1"
    STATE_DIR="$STATE_ROOT/$1"
    LISTING="$STATE_DIR/listing.tsv"
    SOURCE_LOCK="/data/.lock-$1"
}


# fail <message> : logs the error and exits 1.
fail() {
    log "ERROR: $*"
    exit 1
}


# number <name> <value> : fails unless the value is a number without leading zeros (bash arithmetic reads 08 as
# octal).
number() {
    [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] || fail "$1 must be a number, got '$2'."
}


# check_read_subset : whether restic check --read-data-subset takes CHECK_READ_SUBSET: a percentage above 0 and at
# most 100, n/t with n at most t and t at most 256, or a size with a unit. A bad value would fail every run on the check day, after the
# snapshot.
check_read_subset() {
    local v="$CHECK_READ_SUBSET"

    if [[ "$v" =~ ^([0-9]{1,3}(\.[0-9]+)?)%$ ]]; then
        V="${BASH_REMATCH[1]}" gawk 'BEGIN { v = ENVIRON["V"] + 0; exit !(v > 0 && v <= 100) }'
    elif [[ "$v" =~ ^([1-9][0-9]{0,8})/([1-9][0-9]{0,8})$ ]]; then
        (( BASH_REMATCH[1] <= BASH_REMATCH[2] && BASH_REMATCH[2] <= 256 ))
    else
        [[ "$v" =~ ^[1-9][0-9]{0,8}[KMGT]$ ]]
    fi
}


check_global_settings() {
    local v name seen=" "

    (( ${#SOURCE_LIST[@]} > 0 )) || fail "SOURCES is empty: list the source names, e.g. SOURCES=prod dev."
    for name in "${SOURCE_LIST[@]}"; do
        # The name goes into variable names, file names and metric labels.
        [[ "$name" =~ ^[a-z][a-z0-9_]{0,31}$ ]] \
            || fail "source name '$name' must be lower-case letters, digits and _, starting with a letter, up to 32."
        [[ "$seen" != *" $name "* ]] || fail "source '$name' is listed twice in SOURCES."
        seen+="$name "
    done
    for v in KEEP_HOURLY KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY COPY_PORT; do
        number "$v" "${!v}"
    done
    [[ "$CHECK_WEEKDAY" =~ ^[1-7]?$ ]] || fail "CHECK_WEEKDAY must be 1-7 or empty, got '$CHECK_WEEKDAY'."
    check_read_subset || fail "CHECK_READ_SUBSET must be like 10% (above 0, at most 100), 1/5 (n at most t, t at most 256) or 500M, got '$CHECK_READ_SUBSET'."
    [[ "$WAIT_FOR_LOCK" =~ ^(yes|no)$ ]] || fail "WAIT_FOR_LOCK must be yes or no, got '$WAIT_FOR_LOCK'."
    # Without a colon rsync copies to a local path inside the container and reports success.
    if [[ -n "$COPY_TARGET" && "$COPY_TARGET" != *:* ]]; then
        fail "COPY_TARGET must be user@host:path (an empty path after the colon is fine)."
    fi
    if [[ -n "$COPY_TARGET" ]]; then
        [[ -s "$COPY_KEY" && -s "$COPY_KNOWN_HOSTS" ]] || fail "COPY_TARGET is set, but $COPY_KEY or $COPY_KNOWN_HOSTS is missing or empty."
    fi
    [[ -s "$RESTIC_PASSWORD_FILE" ]] || fail "$RESTIC_PASSWORD_FILE is missing or empty."
}


# check_source <name> : the settings and key files of that source (loads it).
check_source() {
    local v up flags

    load_source "$1"
    up="$(upper "$1")"
    [[ -n "$S_BUCKET" ]] || fail "${up}_BUCKET is not set."
    for v in "$S_BUCKET" "$S_PREFIX" "$S_ENDPOINT" "$S_REGION" "$S_PROVIDER" "$S_RCLONE_FLAGS"; do
        [[ "$v" != *$'\n'* ]] || fail "a setting of $1 contains a newline."
    done
    # The bucket and the prefix end up in an rclone path: bucket/prefix.
    [[ "$S_BUCKET" != */* && "$S_BUCKET" != *:* ]] || fail "${up}_BUCKET must be a bare bucket name, without / or :; a path in it goes to ${up}_PREFIX."
    [[ "$S_PATH_STYLE" =~ ^(yes|no)$ ]] || fail "${up}_PATH_STYLE must be yes or no, got '$S_PATH_STYLE'."
    # --dump auth and the like, and --s3-sdk-log-mode, print requests (the access key, signatures, a session token);
    # --log-file writes the log, keys included with -vv, past the key filter of rclone_src.
    # Split as rclone_src splits them: a tab separates flags too.
    read -r -a flags <<<"$S_RCLONE_FLAGS"
    for v in "${flags[@]}"; do
        [[ "$v" != --dump* && "$v" != --log-file* && "$v" != --s3-sdk-log-mode* ]] \
            || fail "the rclone flags of $1 must not contain --dump, --log-file or --s3-sdk-log-mode: they would print the keys."
    done
    number "${up}_KEEP_HOURLY" "$S_KEEP_HOURLY"
    number "${up}_KEEP_DAILY" "$S_KEEP_DAILY"
    number "${up}_KEEP_WEEKLY" "$S_KEEP_WEEKLY"
    number "${up}_KEEP_MONTHLY" "$S_KEEP_MONTHLY"
    # All zero: restic forget would remove nothing and say so, every run.
    (( S_KEEP_HOURLY + S_KEEP_DAILY + S_KEEP_WEEKLY + S_KEEP_MONTHLY > 0 )) || fail "the KEEP_* settings of $1 are all 0."
    for v in "$S_ACCESS_KEY_FILE" "$S_SECRET_KEY_FILE"; do
        [[ -s "$v" ]] || fail "$v is missing or empty."
    done
}


# check_data : fails unless /data is a mount: without it the repository and the copies would go into the container.
check_data() {
    mountpoint -q /data || fail "/data is not mounted: mount the data directory (DATA_DIR in compose)."
}


check_repository() {
    if [[ ! -f "$RESTIC_REPOSITORY/config" ]]; then
        fail "no restic repository in $RESTIC_REPOSITORY. Is the data volume mounted? First install: backup.sh init."
    fi
}


# rclone_src <rclone args...> : runs rclone with the source bucket as the remote "src:". The keys go to rclone in
# its environment, set in a subshell: never on a command line, where ps would show them. rclone's log (stderr)
# goes to stderr prefixed with the source, its stdout as is; returns rclone's exit code.
rclone_src() {
    local flags

    read -r -a flags <<<"$S_RCLONE_FLAGS"
    (
        # Only the settings below and the flags reach rclone: an RCLONE_* variable from the environment (env_file)
        # could send the log past the key filter (RCLONE_LOG_FILE) or change the remote.
        local v
        for v in $(compgen -e); do
            [[ "$v" != RCLONE_* ]] || unset "$v"
        done
        export RCLONE_CONFIG_SRC_TYPE=s3
        export RCLONE_CONFIG_SRC_PROVIDER="$S_PROVIDER"
        export RCLONE_CONFIG_SRC_ENDPOINT="$S_ENDPOINT"
        export RCLONE_CONFIG_SRC_REGION="$S_REGION"
        export RCLONE_CONFIG_SRC_FORCE_PATH_STYLE="$([[ "$S_PATH_STYLE" == yes ]] && echo true || echo false)"
        RCLONE_CONFIG_SRC_ACCESS_KEY_ID="$(<"$S_ACCESS_KEY_FILE")" || exit 1
        RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY="$(<"$S_SECRET_KEY_FILE")" || exit 1
        export RCLONE_CONFIG_SRC_ACCESS_KEY_ID RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY
        exec rclone --config /dev/null --log-format date,time,UTC "$@" "${flags[@]}"
    ) 2> >(K1="$(<"$S_ACCESS_KEY_FILE")" K2="$(<"$S_SECRET_KEY_FILE")" P="[$SRC] " gawk '
        # With -vv rclone logs every option it takes from the environment, the keys included, and request headers
        # carry the access key. The keys are masked by value: as they are, quoted once (Go %q: \ and " escaped) and
        # quoted twice (that inside a JSON log line).
        function esc(s,    i, c, out) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                out = out (c == "\\" || c == "\"" ? "\\" : "") c
            }
            return out
        }
        # hide <line> <text> : the line with every occurrence of the text replaced by ***; no regex involved.
        function hide(s, k,    i, out) {
            if (k == "")
                return s
            out = ""
            while ((i = index(s, k)) > 0) {
                out = out substr(s, 1, i - 1) "***"
                s = substr(s, i + length(k))
            }
            return out s
        }
        BEGIN {
            n = 0
            for (j = 1; j <= 2; j++) {
                k = ENVIRON["K" j]
                key[++n] = esc(esc(k)); key[++n] = esc(k); key[++n] = k
            }
        }
        {
            for (j = 1; j <= n; j++)
                $0 = hide($0, key[j])
            print ENVIRON["P"] $0; fflush()
        }' >&2)
}


# remote_path : the rclone path of the source: src:bucket or src:bucket/prefix.
remote_path() {
    printf 'src:%s%s' "$S_BUCKET" "${S_PREFIX:+/${S_PREFIX#/}}"
}


# sync_source : 0 when rclone copied the bucket and listed it, 1 otherwise (the snapshot is taken either way). The
# listing replaces the previous one only when it is complete.
sync_source() {
    local tmp

    mkdir -p "$MIRROR" "$STATE_DIR" || return 1
    rm -f "$STATE_DIR"/*.tmp.*
    log "rclone: copying $(remote_path) to $MIRROR"
    if ! rclone_src copy "$(remote_path)" "$MIRROR" --use-server-modtime --update --fast-list \
        --stats 5m --stats-one-line --stats-log-level NOTICE; then
        log "ERROR: rclone copy failed"
        return 1
    fi

    # time <TAB> size <TAB> path: the path last, so a tab in a name does not shift the columns.
    tmp="$(mktemp "$STATE_DIR/listing.tmp.XXXXXX")" || return 1
    if ! rclone_src lsf "$(remote_path)" --recursive --files-only --fast-list --use-server-modtime \
        --format tsp --separator $'\t' --time-format RFC3339 >"$tmp"; then
        rm -f "$tmp"
        log "ERROR: rclone could not list the bucket"
        return 1
    fi
    mv "$tmp" "$LISTING" || return 1
    log "rclone: done; the bucket holds $(listing_objects) objects, $(listing_bytes) bytes"
}


listing_objects() {
    gawk 'END { print NR }' "$LISTING"
}


listing_bytes() {
    gawk -F'\t' '{ s += $2 } END { printf "%.0f\n", s }' "$LISTING"
}


# snapshot <retention: yes|no> : under the repository lock, snapshot, forget, the daily prune, the weekly check and
# the off-host copy.
snapshot() {
    exec 8>"$REPO_LOCK"
    if ! flock -n 8; then
        log "restic: waiting for another run to finish with the repository"
        flock 8
    fi

    # Always the same paths, even when empty: restic picks the parent snapshot by the exact path set.
    mkdir -p "$MIRROR" "$STATE_DIR"
    log "restic: snapshot of $MIRROR $STATE_DIR"
    restic backup --quiet --host "$SNAPSHOT_HOST" --tag "$SRC" "$MIRROR" "$STATE_DIR"

    if [[ "$1" == yes ]]; then
        log "restic: retention (hourly $S_KEEP_HOURLY, daily $S_KEEP_DAILY, weekly $S_KEEP_WEEKLY, monthly $S_KEEP_MONTHLY)"
        restic forget --quiet --host "$SNAPSHOT_HOST" --tag "$SRC" --group-by host,tags \
            --keep-hourly "$S_KEEP_HOURLY" --keep-daily "$S_KEEP_DAILY" --keep-weekly "$S_KEEP_WEEKLY" \
            --keep-monthly "$S_KEEP_MONTHLY"
        # Once a day, by the first good run of any source: prune rewrites packs and takes the whole repository.
        if [[ "$(cat "$PRUNE_STAMP" 2>/dev/null)" != "$(date +%F)" ]]; then
            log "restic: prune (once a day)"
            restic prune --quiet
            date +%F >"$PRUNE_STAMP"
        fi
        if [[ -n "$CHECK_WEEKDAY" && "$(date +%u)" == "$CHECK_WEEKDAY" \
            && "$(cat "$CHECK_STAMP" 2>/dev/null)" != "$(date +%F)" ]]; then
            log "restic: weekly check, reading $CHECK_READ_SUBSET of the data"
            restic check --read-data-subset="$CHECK_READ_SUBSET"
            date +%F >"$CHECK_STAMP"
        fi
    fi

    if [[ -n "$COPY_TARGET" ]]; then
        copy_offsite || copy_failed
    fi
    exec 8>&-
}


# copy_offsite : sends the repository files COPY_TARGET does not have yet. Repository files never change once
# written, so adding new ones keeps the copy a valid repository (a superset: pruned packs stay there). Runs under
# the repository lock, so restic writes nothing meanwhile. rsync sorts the list: data/ and index/ go before
# snapshots/, so an interrupted copy never holds a snapshot whose data is missing. A failure does not fail the run.
copy_offsite() {
    local started list

    started="$(date +%s)"
    list="$(mktemp)" || return 1
    (cd "$RESTIC_REPOSITORY" && find . -type f ! -path './locks/*' | sed 's,^\./,,') >"$list" || { rm -f "$list"; return 1; }
    log "copy: restic repository to $COPY_TARGET ($(wc -l <"$list") files, those already there are skipped)"
    if ! rsync --recursive --times --ignore-existing --chmod=D700,F600 --files-from="$list" \
        -e "ssh -i '$COPY_KEY' -p $COPY_PORT -o BatchMode=yes -o StrictHostKeyChecking=yes -o 'UserKnownHostsFile=$COPY_KNOWN_HOSTS'" \
        "$RESTIC_REPOSITORY/" "$COPY_TARGET"; then
        rm -f "$list"
        return 1
    fi
    rm -f "$list"

    write_prom s3_backup_copy.prom <<EOF || return 1
# HELP s3_backup_copy_last_success_timestamp_seconds When the restic repository was last copied off-host.
# TYPE s3_backup_copy_last_success_timestamp_seconds gauge
s3_backup_copy_last_success_timestamp_seconds $(date +%s)
# HELP s3_backup_copy_last_duration_seconds How long the last off-host copy took.
# TYPE s3_backup_copy_last_duration_seconds gauge
s3_backup_copy_last_duration_seconds $(( $(date +%s) - started ))
EOF
    log "copy: done"
}


copy_failed() {
    log "ERROR: copy to $COPY_TARGET failed; the next run tries again."
    write_prom s3_backup_copy_failure.prom <<EOF || true
# HELP s3_backup_copy_last_failure_timestamp_seconds When the last off-host copy failed.
# TYPE s3_backup_copy_last_failure_timestamp_seconds gauge
s3_backup_copy_last_failure_timestamp_seconds $(date +%s)
EOF
}


write_metrics() {
    local duration="$1" objects bucket_bytes files mirror_bytes repo_bytes

    # The snapshot is already taken: a failed count must not turn the run into a failure.
    objects="$(listing_objects)" || objects=NaN
    bucket_bytes="$(listing_bytes)" || bucket_bytes=NaN
    files="$(find "$MIRROR" -type f | wc -l)" || files=NaN
    mirror_bytes="$(du -sb "$MIRROR" | cut -f1)" || mirror_bytes=NaN
    repo_bytes="$(du -sb "$RESTIC_REPOSITORY" | cut -f1)" || repo_bytes=NaN

    write_prom "$(source_prom success)" <<EOF || log "ERROR: could not write the metrics to $METRICS_DIR."
# HELP s3_backup_last_success_timestamp_seconds When the last backup run of a source (rclone + restic snapshot) succeeded.
# TYPE s3_backup_last_success_timestamp_seconds gauge
s3_backup_last_success_timestamp_seconds{source="$SRC"} $(date +%s)
# HELP s3_backup_last_duration_seconds How long the last good run of a source took.
# TYPE s3_backup_last_duration_seconds gauge
s3_backup_last_duration_seconds{source="$SRC"} ${duration}
# HELP s3_backup_bucket_objects Objects in the bucket at the last good run.
# TYPE s3_backup_bucket_objects gauge
s3_backup_bucket_objects{source="$SRC"} ${objects}
# HELP s3_backup_bucket_bytes Size of the objects in the bucket at the last good run.
# TYPE s3_backup_bucket_bytes gauge
s3_backup_bucket_bytes{source="$SRC"} ${bucket_bytes}
# HELP s3_backup_mirror_files Files in the local copy, objects deleted in the bucket included.
# TYPE s3_backup_mirror_files gauge
s3_backup_mirror_files{source="$SRC"} ${files}
# HELP s3_backup_mirror_bytes Size of the local copy.
# TYPE s3_backup_mirror_bytes gauge
s3_backup_mirror_bytes{source="$SRC"} ${mirror_bytes}
EOF
    write_prom s3_backup_repository.prom <<EOF || log "ERROR: could not write the metrics to $METRICS_DIR."
# HELP s3_backup_repository_bytes Size of the restic repository.
# TYPE s3_backup_repository_bytes gauge
s3_backup_repository_bytes ${repo_bytes}
EOF
    log "done: bucket $objects objects $bucket_bytes bytes, copy $files files $mirror_bytes bytes, repository $repo_bytes bytes, ${duration}s"
}


# run_one <source> : one run of one source.
run_one() {
    local started synced=yes

    load_source "$1"
    check_data
    exec 9>"$SOURCE_LOCK"
    if [[ "$WAIT_FOR_LOCK" == yes ]]; then
        flock 9
    elif ! flock -n 9; then
        # Not a failure: a long first copy may still be running at the scheduled time.
        log "another run of $1 holds $SOURCE_LOCK, skipping this one."
        exit 0
    fi

    trap on_exit EXIT
    # A signal would run the EXIT trap with $? = 0: no error, no failure metric.
    trap 'exit 143' TERM
    trap 'exit 130' INT
    started="$(date +%s)"
    check_source "$1"
    check_repository
    sync_source || synced=no
    if [[ "$synced" != yes ]]; then
        log "ERROR: taking the snapshot of what is there, without retention."
    fi
    snapshot "$synced"
    [[ "$synced" == yes ]] || exit 1
    write_metrics "$(( $(date +%s) - started ))"
}


# init : creates the restic repository, once.
init() {
    check_data
    if [[ -f "$RESTIC_REPOSITORY/config" ]]; then
        log "restic: repository in $RESTIC_REPOSITORY already exists, nothing to do"
        return 0
    fi
    restic init
}


# is_source <name> : whether the name is listed in SOURCES.
is_source() {
    local s

    for s in "${SOURCE_LIST[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}


main() {
    local cmd="${1:-run}" s rc=0

    case "$cmd" in
        init|check|run) ;;
        *) log "ERROR: unknown command '$cmd' (run, init, check)"; exit 2 ;;
    esac
    (( $# == 0 )) || shift
    check_global_settings

    case "$cmd" in
        init) init; return ;;
        check)
            for s in "${SOURCE_LIST[@]}"; do
                ( check_source "$s" ) || rc=1
            done
            (( rc == 0 )) && log "settings: ${#SOURCE_LIST[@]} sources, all good"
            return "$rc"
            ;;
    esac

    for s in "$@"; do
        is_source "$s" || { log "ERROR: '$s' is not in SOURCES (${SOURCE_LIST[*]})"; exit 2; }
    done
    if (( $# == 1 )); then
        run_one "$1"
        return
    fi
    # Several sources: each in its own process, so that a failure of one (set -e) does not skip the others.
    (( $# > 0 )) || set -- "${SOURCE_LIST[@]}"
    for s in "$@"; do
        "$0" run "$s" || rc=1
    done
    return "$rc"
}


main "$@"
