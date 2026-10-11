FROM alpine:3.22

# GNU gawk: backup.sh needs awk the busybox applet does not have. util-linux-misc: flock.
# rsync and openssh-client: the optional off-host copy.
RUN apk add --no-cache bash ca-certificates coreutils findutils gawk openssh-client rclone restic rsync supercronic tzdata util-linux-misc

COPY backup.sh entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENV TZ=UTC \
    RESTIC_REPOSITORY=/data/restic \
    RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
    RESTIC_CACHE_DIR=/data/cache
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
