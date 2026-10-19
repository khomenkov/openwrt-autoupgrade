#!/bin/sh
# Удаление автообновления: убирает cron-задачу, кнопки в LuCI и сам скрипт.
#
# Запуск на роутере:
#   wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/uninstall.sh | sh

DEST="${DEST:-/root/upgrade.sh}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"

say() { echo "[uninstall] $*"; }

# cron
if [ -f "$CRON_FILE" ]; then
    grep -vF "$DEST" "$CRON_FILE" > "$CRON_FILE.new" || true
    mv "$CRON_FILE.new" "$CRON_FILE"
    [ -x /etc/init.d/cron ] && /etc/init.d/cron restart
    say "задача cron удалена"
fi

# LuCI
if command -v uci >/dev/null 2>&1; then
    for name in "Обновить пакеты" "Лог обновления"; do
        while idx="$(uci show luci 2>/dev/null | grep -F ".name='$name'" | head -n 1 | cut -d. -f2)"; [ -n "$idx" ]; do
            uci -q delete "luci.$idx" || break
        done
    done
    uci commit luci
    say "команды LuCI удалены"
fi

# скрипт и временные файлы
rm -f "$DEST" /tmp/autoupgrade.lock /tmp/apk-update.log
say "готово (luci-app-commands не удалялся)"
