#!/bin/sh
# Автообновление пакетов для OpenWrt 25.12+ (apk)

LOCK=/tmp/autoupgrade.lock
[ -e "$LOCK" ] && exit 0
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

log() { logger -t autoupgrade "$*"; }

# Нужно минимум ~5 МБ свободного места в overlay
FREE_KB=$(df /overlay | awk 'NR==2 {print $4}')
if [ "${FREE_KB:-0}" -lt 5120 ]; then
    log "not enough space in /overlay (${FREE_KB} KB), skipping"
    exit 1
fi

if ! apk update > /tmp/apk-update.log 2>&1; then
    log "apk update failed: $(tail -n 1 /tmp/apk-update.log)"
    exit 1
fi

UPGRADABLE=$(apk list -u 2>/dev/null | cut -d' ' -f1)
if [ -z "$UPGRADABLE" ]; then
    log "no updates"
    exit 0
fi

log "upgrading: $(echo $UPGRADABLE)"
apk upgrade 2>&1 | logger -t autoupgrade
log "done"
