#!/bin/sh
# Установщик автообновления пакетов для OpenWrt 25.12+ (apk).
#
# Что делает:
#   1. скачивает upgrade.sh из репозитория в /root/upgrade.sh
#   2. добавляет в LuCI (Система -> Пользовательские команды) две кнопки:
#      «Обновить пакеты» и «Лог обновления»
#   3. ставит ежедневный запуск через cron (по умолчанию 12:00 по времени роутера)
#
# Запуск на роутере:
#   wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/install.sh | sh
#
# Переменные окружения (все необязательные):
#   REPO           владелец/репозиторий на GitHub (по умолчанию khomenkov/openwrt-autoupgrade)
#   BRANCH         ветка, тег или хеш коммита (по умолчанию main)
#   DEST           куда положить скрипт (по умолчанию /root/upgrade.sh)
#   CRON_SCHEDULE  расписание cron (по умолчанию "0 12 * * *")
#   NO_CRON=1      не трогать cron
#   NO_LUCI=1      не трогать LuCI и не ставить luci-app-commands
#
# Пример:
#   wget -qO- URL | CRON_SCHEDULE="30 4 * * 0" NO_LUCI=1 sh

set -e

REPO="${REPO:-khomenkov/openwrt-autoupgrade}"
BRANCH="${BRANCH:-main}"
DEST="${DEST:-/root/upgrade.sh}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 12 * * *}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

say()  { echo "[install] $*"; }
warn() { echo "[install] ВНИМАНИЕ: $*" >&2; }
die()  { echo "[install] ОШИБКА: $*" >&2; exit 1; }

fetch() { # fetch URL FILE
    wget -q -O "$2" "$1" 2>/dev/null || uclient-fetch -q -O "$2" "$1" 2>/dev/null
}

command -v apk >/dev/null 2>&1 || die "apk не найден: нужен OpenWrt 25.12 или новее"

# --- 1. upgrade.sh ---------------------------------------------------------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

say "скачиваю $BASE/upgrade.sh"
fetch "$BASE/upgrade.sh" "$TMP" || die "не удалось скачать upgrade.sh (проверьте REPO/BRANCH и доступ к raw.githubusercontent.com)"
head -n 1 "$TMP" | grep -q '^#!/bin/sh' || die "скачанный файл не похож на shell-скрипт"

mkdir -p "$(dirname "$DEST")"
cp "$TMP" "$DEST"
chmod +x "$DEST"
say "скрипт установлен: $DEST"

# --- 2. LuCI: пользовательские команды -------------------------------------
add_luci_cmd() { # add_luci_cmd NAME COMMAND
    # убрать прежнюю запись с таким именем, чтобы повторный запуск не плодил дубли
    while idx="$(uci show luci 2>/dev/null | grep -F ".name='$1'" | head -n 1 | cut -d. -f2)"; [ -n "$idx" ]; do
        uci -q delete "luci.$idx" || break
    done
    sec="$(uci add luci command)"
    uci set "luci.$sec.name=$1"
    uci set "luci.$sec.command=$2"
}

if [ -z "$NO_LUCI" ]; then
    if command -v uci >/dev/null 2>&1; then
        if ! apk info -e luci-app-commands >/dev/null 2>&1; then
            if [ -d /www/luci-static ]; then
                say "ставлю luci-app-commands"
                apk update >/dev/null 2>&1 || true
                apk add luci-app-commands >/dev/null 2>&1 || warn "не удалось поставить luci-app-commands, поставьте вручную: apk add luci-app-commands"
            else
                warn "LuCI не найден, кнопки в веб-интерфейсе не добавляю"
            fi
        fi

        # LuCI разбирает команду по словам и запускает без оболочки: &, |, >, ( ) не работают,
        # поэтому в команде только путь к скрипту и одно слово-режим
        add_luci_cmd "Обновить пакеты" "$DEST bg"
        add_luci_cmd "Лог обновления" "$DEST log"
        uci commit luci
        say "команды добавлены в LuCI (Система -> Пользовательские команды)"
    else
        warn "uci не найден, пропускаю LuCI"
    fi
fi

# --- 3. cron ---------------------------------------------------------------
if [ -z "$NO_CRON" ]; then
    touch "$CRON_FILE"
    grep -vF "$DEST" "$CRON_FILE" > "$CRON_FILE.new" || true
    echo "$CRON_SCHEDULE $DEST >/dev/null 2>&1" >> "$CRON_FILE.new"
    mv "$CRON_FILE.new" "$CRON_FILE"
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enable
        /etc/init.d/cron restart
    fi
    say "cron: $CRON_SCHEDULE (время роутера сейчас: $(date '+%H:%M %Z'))"
fi

say "готово. Запустить вручную: $DEST   Лог: logread | grep autoupgrade | tail -n 40"
