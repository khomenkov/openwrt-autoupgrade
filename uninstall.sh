#!/bin/sh
# Удаление автообновления: убирает cron-задачу, кнопки в LuCI и сам скрипт.
# С PURGE=1 удаляет ещё настройки, историю и копии конфигурации.
#
# Запуск на роутере:
#   wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/uninstall.sh | sh
#   wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/uninstall.sh | PURGE=1 sh

DEST="${DEST:-/root/upgrade.sh}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"
CRON_INIT="${CRON_INIT:-/etc/init.d/cron}"
CONF_FILE="${CONF_FILE:-/etc/config/autoupgrade}"
SYSUPGRADE_CONF="${SYSUPGRADE_CONF:-/etc/sysupgrade.conf}"

say() { echo "[uninstall] $*"; }

# cron
if [ -f "$CRON_FILE" ]; then
	grep -vF "$DEST" "$CRON_FILE" >"$CRON_FILE.new" || true
	mv "$CRON_FILE.new" "$CRON_FILE"
	[ -x "$CRON_INIT" ] && "$CRON_INIT" restart
	say "задача cron удалена"
fi

# LuCI
if command -v uci >/dev/null 2>&1; then
	for name in "Обновить пакеты" "Проверить обновления" "Статус автообновления" "Лог обновления"; do
		while idx="$(uci show luci 2>/dev/null | grep -F ".name='$name'" | head -n 1 | cut -d. -f2)"; [ -n "$idx" ]; do
			uci -q delete "luci.$idx" || break
		done
	done
	uci commit luci
	say "команды LuCI удалены"
fi

# /etc/sysupgrade.conf: убираем только строку со скриптом
if [ -f "$SYSUPGRADE_CONF" ]; then
	grep -vxF "$DEST" "$SYSUPGRADE_CONF" >"$SYSUPGRADE_CONF.new" || true
	mv "$SYSUPGRADE_CONF.new" "$SYSUPGRADE_CONF"
fi

# настройки, история, копии конфигурации (только по явной просьбе)
if [ -n "$PURGE" ]; then
	hist="$(uci -q get autoupgrade.main.history_file 2>/dev/null)"
	hist="${hist:-/root/autoupgrade.history}"
	bdir="$(uci -q get autoupgrade.main.backup_dir 2>/dev/null)"
	bdir="${bdir:-/root/autoupgrade-backup}"
	rm -f "$CONF_FILE"
	[ "$hist" = none ] || rm -f "$hist" "$hist.tmp"
	case "$bdir" in
	*autoupgrade*) rm -rf "$bdir" ;;
	*) say "каталог копий $bdir не похож на каталог автообновления, не удаляю" ;;
	esac
	say "настройки, история и копии конфигурации удалены"
fi

# скрипт и временные файлы
rm -f "$DEST"
rm -rf /tmp/autoupgrade /tmp/autoupgrade.lock /tmp/apk-update.log
say "готово (luci-app-commands не удалялся)"
