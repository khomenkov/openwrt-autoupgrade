#!/bin/sh
# Установщик автообновления пакетов для OpenWrt 25.12+ (apk).
#
# Что делает:
#   1. скачивает upgrade.sh из репозитория в /root/upgrade.sh
#   2. создаёт /etc/config/autoupgrade с настройками по умолчанию
#      (уже существующий файл настроек не трогает)
#   3. добавляет в LuCI (Система -> Пользовательские команды) четыре кнопки:
#      «Обновить пакеты», «Проверить обновления», «Статус автообновления», «Лог обновления»
#   4. ставит запуск по расписанию через cron (по умолчанию 12:00 по времени роутера)
#   5. добавляет скрипт и cron-файл в /etc/sysupgrade.conf, чтобы они
#      пережили обновление прошивки
#
# Повторный запуск безопасен: скрипт обновляется, дублей в LuCI и cron нет,
# ваши настройки и расписание сохраняются.
#
# Запуск на роутере:
#   wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/install.sh | sh
# Если команды wget нет, то же самое через uclient-fetch -qO- или curl -fsSL.
#
# Переменные окружения (все необязательные):
#   REPO           владелец/репозиторий на GitHub (по умолчанию khomenkov/openwrt-autoupgrade)
#   BRANCH         ветка, тег или хеш коммита (по умолчанию main)
#   DEST           куда положить скрипт (по умолчанию /root/upgrade.sh)
#   CRON_SCHEDULE  расписание cron (по умолчанию: уже настроенное, а если его нет, "0 12 * * *")
#   NO_CRON=1      не трогать cron
#   NO_LUCI=1      не трогать LuCI и не ставить luci-app-commands
#   NO_KEEP=1      не трогать /etc/sysupgrade.conf
#
# Пример:
#   wget -qO- URL | CRON_SCHEDULE="30 4 * * 0" NO_LUCI=1 sh

set -e

REPO="${REPO:-khomenkov/openwrt-autoupgrade}"
BRANCH="${BRANCH:-main}"
DEST="${DEST:-/root/upgrade.sh}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
CRON_INIT="${CRON_INIT:-/etc/init.d/cron}"
CONF_FILE="${CONF_FILE:-/etc/config/autoupgrade}"
SYSUPGRADE_CONF="${SYSUPGRADE_CONF:-/etc/sysupgrade.conf}"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

say() { echo "[install] $*"; }
warn() { echo "[install] ВНИМАНИЕ: $*" >&2; }
die() { echo "[install] ОШИБКА: $*" >&2; exit 1; }

fetch() { # fetch URL FILE: пробуем wget, uclient-fetch и curl, что найдётся и сработает
	for _t in wget uclient-fetch curl; do
		command -v "$_t" >/dev/null 2>&1 || continue
		case "$_t" in
		curl) curl -fsSL -o "$2" "$1" 2>/dev/null ;;
		*) "$_t" -q -O "$2" "$1" 2>/dev/null ;;
		esac && return 0
	done
	return 1
}

command -v apk >/dev/null 2>&1 || die "apk не найден: нужен OpenWrt 25.12 или новее"

# --- 1. upgrade.sh -----------------------------------------------------------

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

say "скачиваю $BASE/upgrade.sh"
fetch "$BASE/upgrade.sh" "$TMP" || die "не удалось скачать upgrade.sh (проверьте REPO/BRANCH, доступ к raw.githubusercontent.com и наличие wget, uclient-fetch или curl)"
head -n 1 "$TMP" | grep -q '^#!/bin/sh' || die "скачанный файл не похож на shell-скрипт"
sh -n "$TMP" || die "в скачанном скрипте синтаксическая ошибка, возможно файл загрузился не полностью"

mkdir -p "$(dirname "$DEST")"
cp "$TMP" "$DEST"
chmod +x "$DEST"
say "скрипт установлен: $DEST ($("$DEST" version 2>/dev/null || echo 'версия неизвестна'))"

# --- 2. настройки ------------------------------------------------------------

if [ -e "$CONF_FILE" ]; then
	say "настройки уже есть, не меняю: $CONF_FILE"
else
	mkdir -p "$(dirname "$CONF_FILE")"
	cat >"$CONF_FILE" <<'EOF'
config autoupgrade 'main'
	# 0 - ничего не делать по расписанию (ручные запуски работают)
	option enabled '1'
	# случайная задержка перед запуском по расписанию, секунд (0 - без задержки)
	option jitter '1800'
	# сколько раз пробовать apk update и пауза между попытками, секунд
	option retries '3'
	option retry_delay '120'
	# минимум свободного места в /overlay, КБ
	option min_free_kb '5120'
	# копия настроек (sysupgrade -b) перед обновлением; хранить последних N
	option backup '1'
	option backup_keep '3'
	# после обновления проверить, что роутер резолвит это имя ('none' - не проверять)
	option health_host 'openwrt.org'
	# 1 - перезапускать init-скрипты обновлённых пакетов (network, dropbear, cron не трогаем)
	option restart_services '0'
	# файл истории; 'none' - не вести
	option history_file '/root/autoupgrade.history'

	# уведомления: none, telegram, ntfy или cmd
	option notify 'none'
	# 0 - писать только об ошибках и предупреждениях
	option notify_success '1'
	# option telegram_token ''
	# option telegram_chat_id ''
	# option ntfy_url 'https://ntfy.sh/my-topic'
	# option notify_cmd '/root/my-notify.sh'

	# Пакеты, обновления которых нужно ставить вручную. Если такой пакет есть среди
	# доступных обновлений, запуск по расписанию ничего не ставит и присылает
	# уведомление. Допускаются шаблоны. Вручную: upgrade.sh run
	# list hold 'libc'
	# list hold 'kmod-*'
EOF
	chmod 600 "$CONF_FILE"
	say "создан файл настроек: $CONF_FILE"
fi

# --- 3. LuCI: пользовательские команды ---------------------------------------

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
		add_luci_cmd "Проверить обновления" "$DEST check"
		add_luci_cmd "Статус автообновления" "$DEST status"
		add_luci_cmd "Лог обновления" "$DEST log"
		uci commit luci
		say "команды добавлены в LuCI (Система -> Пользовательские команды)"
	else
		warn "uci не найден, пропускаю LuCI"
	fi
fi

# --- 4. cron -----------------------------------------------------------------

if [ -z "$NO_CRON" ]; then
	touch "$CRON_FILE"
	if [ -z "$CRON_SCHEDULE" ]; then
		# сохраняем расписание, которое уже было настроено
		CRON_SCHEDULE="$(grep -F "$DEST" "$CRON_FILE" | head -n 1 | awk '{ print $1, $2, $3, $4, $5 }')"
		CRON_SCHEDULE="${CRON_SCHEDULE:-0 12 * * *}"
	fi
	grep -vF "$DEST" "$CRON_FILE" >"$CRON_FILE.new" || true
	echo "$CRON_SCHEDULE $DEST cron >/dev/null 2>&1" >>"$CRON_FILE.new"
	mv "$CRON_FILE.new" "$CRON_FILE"
	if [ -x "$CRON_INIT" ]; then
		"$CRON_INIT" enable
		"$CRON_INIT" restart
	fi
	say "cron: $CRON_SCHEDULE (время роутера сейчас: $(date '+%H:%M %Z'))"
fi

# --- 5. сохранение при обновлении прошивки -----------------------------------

if [ -z "$NO_KEEP" ]; then
	touch "$SYSUPGRADE_CONF"
	for keep in "$DEST" "$CRON_FILE"; do
		grep -qxF "$keep" "$SYSUPGRADE_CONF" || echo "$keep" >>"$SYSUPGRADE_CONF"
	done
	say "добавлено в $SYSUPGRADE_CONF: переживёт обновление прошивки"
fi

say "готово."
say "  проверить обновления: $DEST check"
say "  обновить сейчас:      $DEST run"
say "  статус и настройки:   $DEST status ; $CONF_FILE"
