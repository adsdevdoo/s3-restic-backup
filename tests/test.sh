#!/bin/sh
# Tests: builds the image and runs backup.sh against a stub rclone that serves "buckets" from local directories.
# The scenarios run without network and without a real bucket; the first `docker build` needs the internet for the
# Alpine packages. Needs Docker. Usage: sh tests/test.sh
# Each scenario prints its result; the script ends with "FAILED: N" (0 = all good) and exits non-zero on failures.
# The data directory (restic repository, copies, state) carries over from one scenario to the next.
set -u
cd "$(dirname "$0")/.." || exit 1
IMG=s3-restic-backup:test
docker build -q -t "$IMG" . >/dev/null || { echo "build failed"; exit 1; }

d=$(mktemp -d)
cleanup() {
  docker rm -f srb-sched-test >/dev/null 2>&1
  docker run --rm -v "$d:/d" alpine:3.22 rm -rf /d/data /d/metrics /d/secrets /d/bin /d/fake /d/env
  rmdir "$d" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$d/data" "$d/secrets" "$d/metrics" "$d/bin" "$d/fake/b-prod/avatars" "$d/fake/b-dev/images"
# Keys whose text must never show up in the output.
printf 'AKprod-7f3e9c' >"$d/secrets/prod_access_key"
printf 'SKprod-c41d2a' >"$d/secrets/prod_secret_key"
printf 'AKdev-9b1e77' >"$d/secrets/dev_access_key"
printf 'SKdev-0aa5f3' >"$d/secrets/dev_secret_key"
# A source whose secret key has a backslash and a quote: rclone escapes them in its log.
printf 'AKodd-wxyz55' >"$d/secrets/odd_access_key"
printf '%s' 'SKodd\q"z-qrst77' >"$d/secrets/odd_secret_key"
head -c 32 /dev/urandom | base64 >"$d/secrets/restic_password"
echo a >"$d/fake/b-prod/a.jpg"
echo x >"$d/fake/b-prod/avatars/x.png"
echo 1 >"$d/fake/b-dev/images/1.jpg"
echo o >"$d/fake/b-dev/other.txt"
# Settings in an env file: a value with a space would not survive the word splitting of $E. A scenario changes a
# setting in its command: `SOURCES='a b' backup.sh check`.
cat >"$d/env" <<'EOF'
SOURCES=prod dev
PROD_BUCKET=b-prod
PROD_ENDPOINT=https://s3.example
DEV_BUCKET=b-dev
DEV_PREFIX=images
DEV_PATH_STYLE=no
CHECK_WEEKDAY=
EOF
E="--env-file $d/env"
# The stub goes ahead of the real rclone in PATH; the scenario against rclone serve s3 runs with PATH without it.
V="-v $d/data:/data -v $d/secrets:/run/secrets:ro -v $d/metrics:/metrics -v $d/fake:/fake:ro -v $d/bin/rclone:/usr/local/bin/rclone:ro"
FAILED=0
ALL=""

# The stub: copy and lsf only; anything else is a test failure (FORBIDDEN). It checks that the keys of the bucket
# arrived in the environment and prints what it saw on stderr. The scenario in /data/scenario: ok, or
# copyfail:<bucket> / lsffail:<bucket>.
cat >"$d/bin/rclone" <<'EOF'
#!/bin/bash
s=$(cat /data/scenario 2>/dev/null)
cmd=""; remote=""; dest=""; modtime=no
while [ $# -gt 0 ]; do
  case $1 in
    --config|--log-format|--format|--separator|--time-format|--stats|--stats-log-level) shift;;
    --use-server-modtime) modtime=yes;;
    --bwlimit) echo "bwlimit $2" >&2; shift;;
    -*) ;;
    copy|lsf) [ -z "$cmd" ] && cmd=$1;;
    src:*) remote=${1#src:};;
    *) [ -n "$cmd" ] && [ -n "$remote" ] && dest=$1;;
  esac
  shift
done
[ -n "$cmd" ] || { echo "FORBIDDEN rclone command" >&2; exit 9; }
bucket=${remote%%/*}
name=${bucket#b-}
[ "$RCLONE_CONFIG_SRC_ACCESS_KEY_ID" = "$(cat /run/secrets/${name}_access_key)" ] \
  && [ "$RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY" = "$(cat /run/secrets/${name}_secret_key)" ] || { echo "auth bad" >&2; exit 1; }
echo "auth ok $cmd path_style=$RCLONE_CONFIG_SRC_FORCE_PATH_STYLE provider=$RCLONE_CONFIG_SRC_PROVIDER modtime=$modtime" >&2
[ "$s" = "${cmd}fail:$bucket" ] && { echo "ERROR : $cmd failed: AccessDenied" >&2; exit 1; }
case $cmd in
  copy) mkdir -p "$dest" && cp -a "/fake/$remote/." "$dest/";;
  lsf) cd "/fake/$remote" && find . -type f -printf '%TY-%Tm-%TdT%TH:%TM:%TSZ\t%s\t%P\n';;
esac
EOF
chmod +x "$d/bin/rclone"

# check <name> <expected rc> <regexes, ";;"-separated: all must match, !re must not> <scenario> [command]
check() {
  echo "$4" >"$d/data/scenario"
  out=$(docker run --rm --network none $E $V "$IMG" sh -c "( ${5:-backup.sh} ); echo rc=\$?" 2>&1)
  ALL="$ALL
$out"
  rc=$(echo "$out" | sed -n 's/^rc=//p')
  ok=yes
  [ "$rc" = "$2" ] || ok=no
  rest="$3;;"
  while [ -n "$rest" ]; do
    re="${rest%%;;*}"; rest="${rest#*;;}"
    case $re in
      "") ;;
      !*) echo "$out" | grep -qE -- "${re#!}" && ok=no;;
      *) echo "$out" | grep -qE -- "$re" || ok=no;;
    esac
  done
  if [ "$ok" = yes ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (rc=$rc, expected $2, wanted /$3/)"; echo "$out" | tail -8
    FAILED=$((FAILED + 1))
  fi
}

# Without the data volume: no run, no repository in the container layer.
for c in "run prod" init; do
  out=$(docker run --rm --network none $E -v "$d/secrets:/run/secrets:ro" "$IMG" sh -c "backup.sh $c; echo rc=\$?" 2>&1)
  if echo "$out" | grep -q '/data is not mounted' && echo "$out" | grep -q '^rc=1$'; then
    echo "ok   no data volume: $c refused"
  else
    echo "FAIL no data volume: $c refused"; echo "$out" | tail -3; FAILED=$((FAILED + 1))
  fi
done

check "no repository: a run fails"            1 'no restic repository;;!rclone: copying' ok "backup.sh run prod; r=\$?; cat /metrics/s3_backup_source.prod.failure.prom; exit \$r"
check "and the failure metric is written"     1 's3_backup_last_failure_timestamp_seconds\{source="prod"\} [0-9]+' ok "backup.sh run prod; r=\$?; cat /metrics/s3_backup_source.prod.failure.prom; exit \$r"
check "init"                                  0 '' ok "backup.sh init"
check "init again does nothing"               0 'already exists' ok "backup.sh init"
check "check: all good"                       0 '2 sources, all good' ok "backup.sh check"
check "one source"                            0 '\[prod\] auth ok copy path_style=true provider=Other modtime=yes;;\[prod\] auth ok lsf;;bucket 2 objects;;copy 2 files;;restic: prune;;!\[dev\]' ok \
  "backup.sh run prod"
check "metrics of the source"                 0 's3_backup_last_success_timestamp_seconds\{source="prod"\} [0-9]+;;s3_backup_bucket_objects\{source="prod"\} 2;;s3_backup_repository_bytes [0-9]+' ok \
  "backup.sh run prod >/dev/null; r=\$?; cat /metrics/s3_backup_source.prod.success.prom /metrics/s3_backup_repository.prom; exit \$r"
check "rclone flags: global, then per source" 0 '\[prod\] bwlimit 1M;;!bwlimit 2M' ok "RCLONE_FLAGS='--bwlimit 2M' PROD_RCLONE_FLAGS='--bwlimit 1M' backup.sh run prod"
check "prune once a day"                      0 'done: ;;!restic: prune' ok "backup.sh run prod"
check "listing of the bucket kept"            0 '	avatars/x.png$;;	a.jpg$' ok "backup.sh run prod >/dev/null && cat /data/state/prod/listing.tsv"
rm "$d/fake/b-prod/a.jpg"
check "object deleted in the bucket stays"    0 'bucket 1 objects;;copy 2 files' ok "backup.sh run prod"
check "and the listing no longer has it"      0 'avatars/x.png;;!a.jpg' ok "cat /data/state/prod/listing.tsv"
check "and it is in the latest snapshot"      0 '/data/mirror/prod/a.jpg' ok "restic ls latest --tag prod"
check "prefix, path style no"                 0 '\[dev\] auth ok copy path_style=false;;bucket 1 objects;;copy 1 files' ok "backup.sh run dev"
check "only the prefix is copied"             0 '^1.jpg$;;!other' ok "ls /data/mirror/dev"
check "per-source retention"                  0 'retention \(hourly 0, daily 2, weekly 8, monthly 24\)' ok "DEV_KEEP_DAILY=2 backup.sh run dev"
check "snapshots tagged by source"            0 '"/data/mirror/dev";;!"/data/mirror/prod"' ok "restic snapshots --tag dev --json"
check "forget of one source keeps the other"  0 '"/data/mirror/prod"' ok "restic snapshots --tag prod --json"
check "all sources, one fails"                1 '\[prod\] .*done: ;;\[dev\] .*ERROR: rclone copy failed;;without retention;;\[dev\] .*backup failed' copyfail:b-dev "backup.sh"
check "the failed source has its metric"      0 'source="dev"' ok "cat /metrics/s3_backup_source.dev.failure.prom"
check "a failed listing fails the run"        1 'could not list the bucket' lsffail:b-prod "backup.sh run prod"
check "and the old listing stays"             0 'avatars/x.png;;!tmp' ok "cat /data/state/prod/listing.tsv; ls /data/state/prod"
check "weekly check, once a day"              0 'weekly check;;done: ' ok "CHECK_WEEKDAY=\$(date +%u) backup.sh run prod"
check "no second check the same day"          0 '!weekly check;;done: ' ok "CHECK_WEEKDAY=\$(date +%u) backup.sh run prod"
check "source busy: skipped"                  0 'skipping this one;;!rclone: copying' ok "flock /data/.lock-prod sleep 4 & sleep 1; backup.sh run prod"
check "source busy, WAIT_FOR_LOCK=yes: waits" 0 'done: ;;!skipping' ok "flock /data/.lock-prod sleep 3 & sleep 1; WAIT_FOR_LOCK=yes backup.sh run prod"
check "repository busy: waits"                0 'waiting for another run;;done: ' ok "flock /data/.restic.lock sleep 3 & sleep 1; backup.sh run prod"
# The real rclone against rclone serve s3 on the loopback, with -vv: the real flags work, the keys are masked.
check "real rclone, -vv: keys masked"         0 'secret_access_key="\*\*\*";;access_key_id="\*\*\*";;done: bucket 1 objects' ok \
  "/usr/bin/rclone serve s3 --config /dev/null --addr 127.0.0.1:8333 --auth-key \$(cat /run/secrets/prod_access_key),\$(cat /run/secrets/prod_secret_key) /fake >/dev/null 2>&1 & sleep 2; PATH=/usr/bin:/bin PROD_ENDPOINT=http://127.0.0.1:8333 PROD_RCLONE_FLAGS=-vv /usr/local/bin/backup.sh run prod"
check "real rclone: the deleted object stays" 0 '^a.jpg$;;^avatars$' ok "ls /data/mirror/prod"
ODD="/usr/bin/rclone serve s3 --config /dev/null --addr 127.0.0.1:8333 --auth-key \"\$(cat /run/secrets/odd_access_key),\$(cat /run/secrets/odd_secret_key)\" /fake >/dev/null 2>&1 & sleep 2; PATH=/usr/bin:/bin SOURCES='prod odd' ODD_BUCKET=b-prod ODD_ENDPOINT=http://127.0.0.1:8333"
check "real rclone, key with \\ and \": masked" 0 'secret_access_key="\*\*\*";;done: ' ok "$ODD ODD_RCLONE_FLAGS=-vv /usr/local/bin/backup.sh run odd"
check "the same in the JSON log"              0 'secret_access_key=\\"\*\*\*\\";;done: ' ok "$ODD ODD_RCLONE_FLAGS='-vv --use-json-log' /usr/local/bin/backup.sh run odd"
# JSON log: rclone escapes the quotes around the values. An RCLONE_* variable from the environment does not reach
# rclone (RCLONE_LOG_FILE would write the log past the filter).
check "real rclone, JSON log: keys masked, RCLONE_LOG_FILE ignored" 0 'secret_access_key=\\"\*\*\*\\";;access_key_id=\\"\*\*\*\\";;done: ;;no log file' ok \
  "/usr/bin/rclone serve s3 --config /dev/null --addr 127.0.0.1:8333 --auth-key \$(cat /run/secrets/prod_access_key),\$(cat /run/secrets/prod_secret_key) /fake >/dev/null 2>&1 & sleep 2; PATH=/usr/bin:/bin PROD_ENDPOINT=http://127.0.0.1:8333 PROD_RCLONE_FLAGS='-vv --use-json-log' RCLONE_LOG_FILE=/data/rclone.log /usr/local/bin/backup.sh run prod; r=\$?; [ -e /data/rclone.log ] || echo 'no log file'; exit \$r"
check "unknown source"                        2 "'nope' is not in SOURCES" ok "backup.sh run nope"
check "unknown command"                       2 "unknown command 'bogus'" ok "backup.sh bogus"
check "bad source name"                       1 "source name 'Prod'" ok "SOURCES=Prod backup.sh check"
check "source listed twice"                   1 'listed twice' ok "SOURCES='prod prod' backup.sh check"
check "empty SOURCES"                         1 'SOURCES is empty' ok "SOURCES= backup.sh check"
check "bucket not set"                        1 'EXTRA_BUCKET is not set' ok "SOURCES='prod extra' backup.sh check"
check "key files missing"                     1 'extra_access_key is missing' ok "SOURCES='prod extra' EXTRA_BUCKET=x backup.sh check"
check "bucket with a slash"                   1 'bare bucket name' ok "PROD_BUCKET=b/x backup.sh check"
check "bad number"                            1 'PROD_KEEP_DAILY must be a number' ok "PROD_KEEP_DAILY=08 backup.sh check"
check "retention all zero"                    1 'KEEP_\* settings of prod are all 0' ok "PROD_KEEP_DAILY=0 PROD_KEEP_WEEKLY=0 PROD_KEEP_MONTHLY=0 backup.sh check"
check "bad path style"                        1 'PROD_PATH_STYLE must be yes or no' ok "PROD_PATH_STYLE=true backup.sh check"
check "--dump refused"                        1 'must not contain --dump' ok "PROD_RCLONE_FLAGS='-v --dump headers' backup.sh check"
check "--log-file refused"                    1 'must not contain --dump, --log-file' ok "RCLONE_FLAGS='-vv --log-file=/data/x.log' backup.sh check"
check "--s3-sdk-log-mode refused"             1 'must not contain --dump, --log-file or --s3-sdk-log-mode' ok "RCLONE_FLAGS='-vv --s3-sdk-log-mode Request' backup.sh check"
check "--dump after a tab refused"            1 'must not contain --dump' ok "PROD_RCLONE_FLAGS=\"\$(printf -- '-v\\t--dump\\tauth')\" backup.sh check"
for v in bogus 0% 150% 3/2 100 1/257; do
  check "bad CHECK_READ_SUBSET $v"            1 'CHECK_READ_SUBSET must be' ok "CHECK_READ_SUBSET=$v backup.sh check"
done
for v in 10% 2.5% 100% 1/5 5/5 500M; do
  check "good CHECK_READ_SUBSET $v"           0 'all good' ok "CHECK_READ_SUBSET=$v backup.sh check"
done
check "COPY_TARGET without colon"             1 'COPY_TARGET must be' ok "COPY_TARGET=nocolon backup.sh check"
check "COPY_TARGET without a key"             1 'copy_ssh_key or .* is missing' ok "COPY_TARGET=u@h: backup.sh check"

# The keys never show up in the output.
# The odd keys by a fragment, which shows up in any escaped form too.
if echo "$ALL" | grep -qE 'AKprod-7f3e9c|SKprod-c41d2a|AKdev-9b1e77|SKdev-0aa5f3|wxyz55|qrst77'; then
  echo "FAIL a key showed up in the output"; FAILED=$((FAILED + 1))
else
  echo "ok   no key in the output"
fi
if echo "$ALL" | grep -q FORBIDDEN; then
  echo "FAIL rclone got a command other than copy or lsf"; FAILED=$((FAILED + 1))
else
  echo "ok   rclone only ever copied and listed"
fi

# The scheduler starts as PID 1, with one crontab line per source, and stays up.
docker rm -f srb-sched-test >/dev/null 2>&1
docker run -d --name srb-sched-test $E -v "$d/secrets:/run/secrets:ro" -e DEV_SCHEDULE='*/5 * * * *' "$IMG" >/dev/null
sleep 4
if docker ps --filter name=srb-sched-test --format '{{.Status}}' | grep -q '^Up' \
  && docker exec srb-sched-test cat /tmp/crontab | grep -qxF '30 4 * * * /usr/local/bin/backup.sh run prod' \
  && docker exec srb-sched-test cat /tmp/crontab | grep -qxF '*/5 * * * * /usr/local/bin/backup.sh run dev'; then
  echo "ok   scheduler stays up, a line per source"
else
  echo "FAIL scheduler"; docker logs srb-sched-test 2>&1 | tail -5; FAILED=$((FAILED + 1))
fi
docker rm -f srb-sched-test >/dev/null 2>&1

# Bad settings or a bad schedule stop the container at start.
for args in "-e SOURCES=" "-e PROD_SCHEDULE=bogus"; do
  docker run -d --name srb-sched-test $E -v "$d/secrets:/run/secrets:ro" $args "$IMG" >/dev/null
  sleep 3
  if docker ps -a --filter name=srb-sched-test --format '{{.Status}}' | grep -q '^Exited (1)'; then
    echo "ok   container stops at start: $args"
  else
    echo "FAIL container should stop at start: $args"; docker logs srb-sched-test 2>&1 | tail -5; FAILED=$((FAILED + 1))
  fi
  docker rm -f srb-sched-test >/dev/null 2>&1
done

echo "FAILED: $FAILED"
[ "$FAILED" -eq 0 ]
