#!/bin/sh
# Автообновление пакетов для OpenWrt 25.12+ (apk).
# https://github.com/khomenkov/openwrt-autoupgrade
#
# Использование: upgrade.sh [команда]
#   run      обновить пакеты сейчас (по умолчанию; без задержки и без hold-списка)
#   cron     запуск по расписанию: enabled, случайная задержка, hold-список
#   bg       запустить run в фоне и сразу вернуться (кнопка в LuCI)
#   check    показать доступные обновления, ничего не устанавливая
#   status   настройки, расписание, последние события
#   log      история обновлений и системный лог
#   version  версия скрипта
#
# Настройки лежат в /etc/config/autoupgrade (UCI). Все они необязательны,
# значения по умолчанию описаны в README.

VERSION="0.2.0"
TAG="autoupgrade"
PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
WORK="${AUTOUPGRADE_WORK:-/tmp/autoupgrade}"
INITD="${AUTOUPGRADE_INITD:-/etc/init.d}"
CRON_FILE="${AUTOUPGRADE_CRON_FILE:-/etc/crontabs/root}"
HOST=$(uname -n 2>/dev/null || echo router)
LOCK="$WORK/lock"

# --- настройки ---------------------------------------------------------------

cfg() { # cfg ОПЦИЯ ЗНАЧЕНИЕ_ПО_УМОЛЧАНИЮ
	_v=$(uci -q get "autoupgrade.main.$1" 2>/dev/null)
	printf '%s' "${_v:-$2}"
}

cfgn() { # то же для чисел: при мусоре в конфиге берём значение по умолчанию
	_n=$(cfg "$1" "$2")
	case "$_n" in
	'' | *[!0-9]*) printf '%s' "$2" ;;
	*) printf '%s' "$_n" ;;
	esac
}

HISTORY=$(cfg history_file /root/autoupgrade.history)
[ "$HISTORY" = none ] && HISTORY=""

# --- журнал ------------------------------------------------------------------

msg() { # в системный лог, а в консоли ещё и на экран
	logger -t "$TAG" "$*"
	[ -t 1 ] && printf '%s\n' "$*"
	return 0
}

event() { # значимое событие: дополнительно в файл истории (пустые прогоны туда не пишем)
	msg "$*"
	[ -n "$HISTORY" ] || return 0
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >>"$HISTORY"
	_lines=$(wc -l <"$HISTORY")
	if [ "${_lines:-0}" -gt 200 ]; then
		tail -n 100 "$HISTORY" >"$HISTORY.tmp" && mv "$HISTORY.tmp" "$HISTORY"
	fi
	return 0
}

fail() {
	event "ERROR: $*"
	notify "$HOST: autoupgrade ERROR: $*"
	exit 1
}

# --- уведомления -------------------------------------------------------------

json_escape() { # stdin -> текст, безопасный внутри JSON-строки
	tr '\t\r' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
		awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }'
}

http_post() { # http_post URL ТЕЛО [CONTENT-TYPE]
	_ct="${3:-text/plain}"
	if command -v curl >/dev/null 2>&1; then
		curl -fsS -m 20 -H "Content-Type: $_ct" --data-binary "$2" "$1" >/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 20 -O /dev/null --header="Content-Type: $_ct" --post-data="$2" "$1"
	else
		uclient-fetch -q -T 20 -O /dev/null --header="Content-Type: $_ct" --post-data="$2" "$1"
	fi
}

notify_telegram() {
	_tok=$(cfg telegram_token "")
	_chat=$(cfg telegram_chat_id "")
	if [ -z "$_tok" ] || [ -z "$_chat" ]; then
		msg "notify: telegram_token and telegram_chat_id must be set"
		return 1
	fi
	_text=$(printf '%s' "$1" | json_escape)
	http_post "https://api.telegram.org/bot$_tok/sendMessage" \
		"{\"chat_id\":\"$_chat\",\"text\":\"$_text\"}" application/json
}

notify() { # notify ТЕКСТ; ошибки доставки не должны ломать обновление
	case "$(cfg notify none)" in
	telegram) notify_telegram "$1" ;;
	ntfy)
		_url=$(cfg ntfy_url "")
		[ -n "$_url" ] && http_post "$_url" "$1" text/plain
		;;
	cmd)
		_cmd=$(cfg notify_cmd "")
		# shellcheck disable=SC2086 # команда может состоять из нескольких слов
		[ -n "$_cmd" ] && $_cmd "$1"
		;;
	*) return 0 ;;
	esac || msg "notify failed"
	return 0
}

# --- замок -------------------------------------------------------------------

acquire_lock() {
	mkdir -p "$WORK" || return 1
	if ! mkdir "$LOCK" 2>/dev/null; then
		_pid=$(cat "$LOCK/pid" 2>/dev/null)
		# пустой pid: другой экземпляр только что создал замок; живой pid: он работает
		if [ -z "$_pid" ] || kill -0 "$_pid" 2>/dev/null; then
			return 1
		fi
		rm -rf "$LOCK" # замок остался от убитого процесса
		mkdir "$LOCK" 2>/dev/null || return 1
	fi
	echo $$ >"$LOCK/pid"
	trap 'rm -rf "$LOCK"' EXIT
	trap 'exit 1' INT TERM HUP
	return 0
}

# --- вспомогательное ---------------------------------------------------------

rand_below() { # случайное целое от 0 до N-1 (в ash нет $RANDOM)
	awk -v n="$1" -v s="$(tr -d . </proc/uptime | cut -d' ' -f1)$$" \
		'BEGIN { srand(s); print int(rand() * n) }'
}

free_kb() {
	_d=/overlay
	[ -d "$_d" ] || _d=/
	df -k "$_d" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

strip_ver() { # name-1.2.3-r1 -> name
	sed 's/-[0-9][^-]*-r[0-9]*$//'
}

pending_names() {
	apk list -u 2>/dev/null | cut -d' ' -f1 | strip_ver
}

pending_plan() { # строки "старая -> новая"; при неожиданном формате вывода просто имена
	_raw=$(apk list -u 2>/dev/null)
	[ -n "$_raw" ] || return 0
	_pairs=$(printf '%s\n' "$_raw" |
		sed -n 's/^\([^ ]*\) .*\[upgradable from: \([^]]*\)\].*$/\2 -> \1/p')
	if [ -n "$_pairs" ]; then
		printf '%s\n' "$_pairs"
	else
		printf '%s\n' "$_raw" | cut -d' ' -f1
	fi
}

snapshot() {
	apk list -I 2>/dev/null | cut -d' ' -f1 | sort
}

changed_names() { # какие пакеты реально изменились (сравнение списков до и после)
	if [ -s "$WORK/before" ] && [ -s "$WORK/after" ]; then
		grep -vxFf "$WORK/before" "$WORK/after" | strip_ver
	else
		cat "$WORK/planned"
	fi
}

hold_hits() { # ожидающие обновления, попавшие в hold-список (допустимы шаблоны вроде kmod-*)
	_holds=$(cfg hold "")
	[ -n "$_holds" ] || return 0
	for _p in $(pending_names); do
		for _h in $_holds; do
			# shellcheck disable=SC2254 # шаблон из конфига должен работать как glob
			case "$_p" in $_h) printf '%s\n' "$_p" ;; esac
		done
	done
}

apk_update() { # apk_update [ЧИСЛО_ПОПЫТОК]
	_tries=${1:-$(cfgn retries 3)}
	_delay=$(cfgn retry_delay 120)
	_i=1
	while :; do
		if apk update >"$WORK/update.log" 2>&1; then
			return 0
		fi
		[ "$_i" -ge "$_tries" ] && return 1
		msg "apk update failed (try $_i of $_tries): $(tail -n 1 "$WORK/update.log"); retrying in ${_delay}s"
		sleep "$_delay"
		_i=$((_i + 1))
	done
}

backup_config() {
	[ "$(cfg backup 1)" = 1 ] || return 0
	command -v sysupgrade >/dev/null 2>&1 || return 0
	_dir=$(cfg backup_dir /root/autoupgrade-backup)
	_keep=$(cfgn backup_keep 3)
	mkdir -p "$_dir" || return 0
	_f="$_dir/config-$(date +%Y%m%d-%H%M%S).tar.gz"
	if sysupgrade -b "$_f" >/dev/null 2>&1; then
		msg "config backup saved: $_f"
		ls -1t "$_dir"/config-*.tar.gz 2>/dev/null | tail -n +$((_keep + 1)) |
			while read -r _old; do rm -f "$_old"; done
	else
		rm -f "$_f"
		msg "config backup failed, continuing without it"
	fi
}

init_scripts() { # имена init-скриптов, которыми владеет пакет $1
	_found=$(apk info -L "$1" 2>/dev/null |
		sed -n 's#^/\{0,1\}etc/init\.d/\([^ /]*\)$#\1#p')
	if [ -z "$_found" ] && [ -x "$INITD/$1" ]; then
		_found="$1"
	fi
	[ -z "$_found" ] || printf '%s\n' "$_found"
}

restart_services() { # restart_services ИМЕНА_ПАКЕТОВ
	[ "$(cfg restart_services 0)" = 1 ] || return 0
	_done=""
	for _p in $1; do
		for _s in $(init_scripts "$_p"); do
			case "$_s" in
			network | boot | cron | dropbear | log) continue ;; # эти не трогаем
			esac
			case " $_done " in *" $_s "*) continue ;; esac
			if [ -x "$INITD/$_s" ] && "$INITD/$_s" enabled; then
				msg "restarting service: $_s"
				"$INITD/$_s" restart >/dev/null 2>&1 || msg "restart of $_s failed"
				_done="$_done $_s"
			fi
		done
	done
}

reboot_hint() { # reboot_hint ИМЕНА_ПАКЕТОВ -> какие из них требуют перезагрузки
	_list=$(cfg reboot_pkgs "libc busybox procd ubus ubusd base-files libubox")
	_hit=""
	for _p in $1; do
		for _r in $_list; do
			[ "$_p" = "$_r" ] && _hit="$_hit $_p"
		done
	done
	printf '%s' "${_hit# }"
}

health_check() { # после обновления проверяем, что DNS на роутере отвечает
	_host=$(cfg health_host openwrt.org)
	[ -n "$_host" ] && [ "$_host" != none ] || return 0
	command -v nslookup >/dev/null 2>&1 || return 0
	_i=1
	while [ "$_i" -le 3 ]; do
		nslookup "$_host" >/dev/null 2>&1 && return 0
		sleep 10
		_i=$((_i + 1))
	done
	return 1
}

# --- команды -----------------------------------------------------------------

do_run() { # do_run manual|cron
	_mode=$1
	acquire_lock || {
		msg "another autoupgrade run is in progress, exiting"
		exit 0
	}

	if [ "$_mode" = cron ]; then
		[ "$(cfg enabled 1)" = 1 ] || {
			msg "disabled in /etc/config/autoupgrade, skipping"
			exit 0
		}
		_j=$(cfgn jitter 1800)
		if [ "$_j" -gt 0 ]; then
			_d=$(rand_below "$_j")
			msg "random start delay: ${_d}s"
			sleep "$_d"
		fi
	fi

	_free=$(free_kb)
	_min=$(cfgn min_free_kb 5120)
	[ "${_free:-0}" -ge "$_min" ] || fail "not enough free space (${_free:-?} KB, need $_min KB)"

	apk_update || fail "apk update failed: $(tail -n 1 "$WORK/update.log" 2>/dev/null)"

	pending_plan >"$WORK/plan"
	if [ ! -s "$WORK/plan" ]; then
		msg "no updates"
		rm -f "$WORK/last_hold"
		exit 0
	fi
	pending_names >"$WORK/planned"
	_names=$(cat "$WORK/planned")
	_count=$(wc -l <"$WORK/plan" | tr -d ' ')

	if [ "$_mode" = cron ]; then
		_hits=$(hold_hits | tr '\n' ' ')
		if [ -n "$_hits" ]; then
			msg "held by the hold list, skipping: $_hits"
			if [ "$(cat "$WORK/last_hold" 2>/dev/null)" != "$_hits" ]; then
				printf '%s' "$_hits" >"$WORK/last_hold"
				event "held by the hold list, install manually with '$SELF run': $_hits"
				notify "$HOST: updates are waiting for a manual install (hold list): $_hits- run: $SELF run"
			fi
			exit 0
		fi
	fi

	event "upgrading $_count package(s): $(echo "$_names" | tr '\n' ' ')"
	logger -t "$TAG" <"$WORK/plan"
	backup_config
	snapshot >"$WORK/before"

	apk upgrade >"$WORK/upgrade.log" 2>&1
	_rc=$?
	logger -t "$TAG" <"$WORK/upgrade.log"
	[ "$_rc" -eq 0 ] || fail "apk upgrade exited with code $_rc: $(tail -n 3 "$WORK/upgrade.log" | tr '\n' ' ')"

	snapshot >"$WORK/after"
	_changed=$(changed_names)
	[ -n "$_changed" ] || _changed=$_names

	restart_services "$_changed"
	_reboot=$(reboot_hint "$_changed")
	_warn=""
	if ! health_check; then
		_warn="DNS check for $(cfg health_host openwrt.org) failed after the upgrade"
	fi

	_shown=$(head -n 15 "$WORK/plan")
	if [ "$_count" -gt 15 ]; then
		_shown="$_shown
... and $((_count - 15)) more"
	fi
	_report="$HOST: upgraded $_count package(s)
$_shown"
	if [ -n "$_reboot" ]; then
		_report="$_report
Reboot recommended (updated: $_reboot)"
	fi
	if [ -n "$_warn" ]; then
		_report="$_report
WARNING: $_warn"
	fi

	event "done: upgraded $_count package(s)${_reboot:+, reboot recommended ($_reboot)}${_warn:+, WARNING: $_warn}"
	if [ -n "$_warn" ] || [ "$(cfg notify_success 1)" = 1 ]; then
		notify "$_report"
	fi
	exit 0
}

do_check() {
	acquire_lock || {
		echo "autoupgrade is running right now, try again later"
		exit 1
	}
	if ! apk_update 1; then
		echo "apk update failed:"
		tail -n 3 "$WORK/update.log"
		exit 1
	fi
	_plan=$(pending_plan)
	if [ -z "$_plan" ]; then
		echo "No updates available."
		exit 0
	fi
	echo "Updates available: $(printf '%s\n' "$_plan" | wc -l | tr -d ' ')"
	echo "$_plan"
	_hits=$(hold_hits | tr '\n' ' ')
	[ -z "$_hits" ] || echo "Held by the hold list (scheduled runs will skip them): $_hits"
	echo "Install now: $SELF run"
}

do_status() {
	echo "openwrt-autoupgrade $VERSION"
	echo "script:           $SELF"
	echo "enabled:          $(cfg enabled 1)"
	_c=$(grep -F "$SELF" "$CRON_FILE" 2>/dev/null | head -n 1)
	echo "cron:             ${_c:-not set}"
	echo "notifications:    $(cfg notify none)"
	echo "hold list:        $(cfg hold "-")"
	echo "restart services: $(cfg restart_services 0)"
	echo "config backup:    $(cfg backup 1)"
	echo "history file:     ${HISTORY:-disabled}"
	if [ -d "$LOCK" ]; then echo "state:            running now"; else echo "state:            idle"; fi
	if [ -n "$HISTORY" ] && [ -s "$HISTORY" ]; then
		echo "last events:"
		tail -n 5 "$HISTORY"
	fi
}

do_log() {
	if [ -n "$HISTORY" ] && [ -s "$HISTORY" ]; then
		echo "== history ($HISTORY)"
		tail -n 20 "$HISTORY"
	fi
	echo "== system log"
	{ logread -e "$TAG" 2>/dev/null || logread 2>/dev/null | grep "$TAG"; } | tail -n 40
}

usage() {
	cat <<'EOF'
Usage: upgrade.sh [command]
  run      install updates now (default)
  cron     scheduled run: honours enabled, random delay and the hold list
  bg       run in the background and return immediately
  check    list available updates without installing
  status   settings, schedule, last events
  log      update history and system log
  version  print the version
EOF
}

case "${1:-run}" in
run) do_run manual ;;
cron) do_run cron ;;
bg)
	(sh "$SELF" run </dev/null >/dev/null 2>&1 &)
	echo "Started in the background. Result: $SELF log"
	;;
check) do_check ;;
status) do_status ;;
log) do_log ;;
version | -v | --version) echo "openwrt-autoupgrade $VERSION" ;;
help | -h | --help) usage ;;
*)
	usage >&2
	exit 2
	;;
esac
