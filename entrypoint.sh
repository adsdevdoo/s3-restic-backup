#!/usr/bin/env bash
# No arguments: check the settings, then run the scheduler: one crontab line per source in SOURCES, `backup.sh run
# <source>` on <SOURCE>_SCHEDULE, or SCHEDULE (cron syntax, default daily 04:30 in TZ).
# With arguments: run them instead, e.g. `docker compose run --rm s3-backup backup.sh init`.
set -euo pipefail

if [[ "$#" -gt 0 ]]; then
    exec "$@"
fi

# Bad settings stop the container here, visibly, instead of failing every scheduled run.
/usr/local/bin/backup.sh check

read -r -a sources <<<"${SOURCES:-}"
: >/tmp/crontab
for s in "${sources[@]}"; do
    # backup.sh check validated the name: lower-case letters, digits and _.
    var="${s^^}_SCHEDULE"
    schedule="${!var:-${SCHEDULE:-30 4 * * *}}"
    if [[ "$schedule" == *$'\n'* ]]; then
        echo "ERROR: $var or SCHEDULE contains a newline." >&2
        exit 1
    fi
    echo "$schedule /usr/local/bin/backup.sh run $s" >>/tmp/crontab
done
# supercronic refuses a crontab line it cannot parse; check before starting, so a typo stops the container.
/usr/bin/supercronic -test /tmp/crontab
# Absolute path: as PID 1 supercronic re-executes itself by argv[0] to reap children.
exec /usr/bin/supercronic -passthrough-logs /tmp/crontab
