# openwrt-autoupgrade

Автообновление пакетов для OpenWrt 25.12+ (менеджер пакетов `apk`).
Проверено на логике для Cudy WR3000P и TR3000 (mediatek/filogic), но скрипты не привязаны к архитектуре.

## Что ставится

- `/root/upgrade.sh` — `apk update` и `apk upgrade`, результат пишется в системный лог с тегом `autoupgrade`
- две кнопки в LuCI (Система → Пользовательские команды): «Обновить пакеты» и «Лог обновления»
- ежедневный запуск через cron, по умолчанию в 12:00 по времени роутера

## Установка

На роутере по SSH:

```sh
wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/install.sh | sh
```

Повторный запуск той же команды обновляет скрипт и не создаёт дублей в LuCI и cron.

### Параметры

Задаются переменными перед `sh`:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `REPO` | `khomenkov/openwrt-autoupgrade` | репозиторий на GitHub |
| `BRANCH` | `main` | ветка, тег или хеш коммита |
| `DEST` | `/root/upgrade.sh` | куда положить скрипт |
| `CRON_SCHEDULE` | `0 12 * * *` | расписание cron |
| `NO_CRON` | не задано | `1` — не трогать cron |
| `NO_LUCI` | не задано | `1` — не трогать LuCI |

Пример: запуск по воскресеньям в 04:30 и без LuCI:

```sh
wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/install.sh | CRON_SCHEDULE="30 4 * * 0" NO_LUCI=1 sh
```

## Ручное использование

```sh
/root/upgrade.sh        # обновить пакеты прямо в консоли
/root/upgrade.sh bg     # запустить в фоне и сразу вернуться
/root/upgrade.sh log    # последние 40 строк лога обновлений
```

Именно эти `bg` и `log` вызывают кнопки в LuCI: там команда выполняется без оболочки, поэтому `&`, `|` и скобки в ней не работают.

Скрипт пропускает запуск, если в `/overlay` меньше ~5 МБ свободного места, и не запускается дважды одновременно (замок `/tmp/autoupgrade.lock`).

## Удаление

```sh
wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/main/uninstall.sh | sh
```

## Публикация репозитория

1. Создайте на GitHub публичный репозиторий `openwrt-autoupgrade`. Для `raw.githubusercontent.com` без токена репозиторий должен быть публичным.
2. Загрузите в корень файлы `install.sh`, `upgrade.sh`, `uninstall.sh`, `README.md`.
3. Если назовёте репозиторий иначе или зальёте его под другим аккаунтом, передавайте `REPO=владелец/имя` при установке или поправьте значение по умолчанию в `install.sh`.

## Безопасность

Команда `wget ... | sh` выполняет код из интернета с правами root. Если хотите защититься от случайных изменений, ставьте с конкретного коммита или тега:

```sh
wget -qO- https://raw.githubusercontent.com/khomenkov/openwrt-autoupgrade/<коммит>/install.sh | BRANCH=<коммит> sh
```

## Требования

- OpenWrt 25.12+ с `apk`
- HTTPS в `wget` (в стандартной сборке есть через `uclient-fetch` и `ca-bundle`)
- для кнопок в LuCI — `luci-app-commands` (установщик ставит его сам, если LuCI есть)
