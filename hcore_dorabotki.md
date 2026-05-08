# План доработок hcore: устойчивое скачивание, safe update/upgrade и управление сервисом

## 1. Краткое резюме проблемы

В текущей версии `install.sh` проект устанавливает `hiddify-core` как transparent proxy: создаёт systemd-сервисы, пишет proxy-переменные окружения и добавляет правила `iptables` для перехвата исходящего TCP/DNS-трафика.

Основные проблемы:

- скачивание дистрибутива `hiddify-core` может обрываться по timeout, потому что используется простой `curl` без retry/resume;
- `update` подписки может не работать после включения transparent proxy, потому что активные proxy env и `iptables` продолжают перехватывать сетевые запросы;
- `upgrade` бинаря имеет ту же проблему: GitHub API и GitHub Releases могут оказаться недоступны из-за собственного proxy-режима;
- управление командами `status`, `update`, `upgrade`, `test` сейчас завязано на запуск `install.sh`, а после установки логичнее иметь штатный installed CLI или systemd-интеграцию.

---

## 2. Что уже есть в проекте

По текущему `README.md` заявлены:

- установка `hiddify-core` в transparent proxy режиме;
- автоматическая загрузка последнего бинаря с GitHub Releases;
- генерация конфига из subscription URL;
- перехват TCP через `iptables`;
- перехват DNS;
- systemd-автозапуск;
- команды `update`, `upgrade`, `status`, `test`, `uninstall`.

Фактически в `install.sh` уже есть:

- `get_latest_version()`;
- `download_binary()`;
- `generate_config()`;
- `iptables_add()`;
- `iptables_del()`;
- `write_iptables_helper()`;
- `write_service()`;
- `write_env_profile()`;
- `cmd_update()`;
- `cmd_upgrade()`;
- `cmd_uninstall()`.

---

## 3. Проблема 1: скачивание бинаря разорвано по timeout

### Текущее поведение

Скачивание выполняется примерно так:

```bash
curl -fsSL --progress-bar "$url" -o "${tmp}/${asset}" \
  || die "Download failed: $url"
```

Недостатки:

- нет `--retry`;
- нет `--retry-all-errors`;
- нет `--connect-timeout`;
- нет ограничения общего времени;
- нет resume через `-C -`;
- нет fallback на `wget`;
- нет контрольной проверки размера архива;
- временный файл сразу считается итоговым.

### Предлагаемое решение

Добавить универсальную функцию `download_file()`:

```bash
download_file() {
  local url="$1"
  local out="$2"

  rm -f "${out}.part"

  info "Downloading: $url"

  if command -v curl >/dev/null 2>&1; then
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        -u all_proxy -u ALL_PROXY \
      curl -fL --progress-bar \
        --connect-timeout 20 \
        --max-time 900 \
        --retry 8 \
        --retry-delay 5 \
        --retry-max-time 900 \
        --retry-all-errors \
        -C - \
        "$url" \
        -o "${out}.part"
  elif command -v wget >/dev/null 2>&1; then
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        -u all_proxy -u ALL_PROXY \
      wget --tries=8 \
           --timeout=30 \
           --continue \
           -O "${out}.part" \
           "$url"
  else
    die "Neither curl nor wget found"
  fi

  [[ -s "${out}.part" ]] || die "Downloaded file is empty: ${out}.part}"
  mv -f "${out}.part" "$out"
}
```

И заменить в `download_binary()`:

```bash
download_file "$url" "${tmp}/${asset}"
```

---

## 4. Проблема 2: update невозможен при включённом proxy + iptables

### Текущее поведение

`cmd_update()` останавливает только основной сервис:

```bash
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
```

Но отдельный сервис `hiddify-iptables.service` остаётся активным. Его `RemainAfterExit=yes`, а правила NAT продолжают работать до явного `ExecStop`.

Итог: команда обновления подписки может пытаться скачать новый конфиг через уже включённый transparent proxy.

### Правильная логика safe update

Перед сетевыми операциями нужно:

1. остановить основной сервис;
2. остановить `hiddify-iptables.service`;
3. временно отключить proxy env в текущем процессе;
4. выполнить скачивание подписки/конфига напрямую;
5. запустить `hiddify-iptables.service`;
6. запустить основной сервис;
7. выполнить тест.

### Новые helper-функции

```bash
proxy_env_unset() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  unset all_proxy ALL_PROXY no_proxy NO_PROXY
}

proxy_rules_down() {
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-iptables" 2>/dev/null || true
  iptables_del 2>/dev/null || true
}

proxy_rules_up() {
  systemctl start "${SERVICE_NAME}-iptables" 2>/dev/null || true
  systemctl start "${SERVICE_NAME}" 2>/dev/null || true
}
```

### Обновлённый `cmd_update()`

```bash
cmd_update() {
  require_root
  [[ -f "$(sub_url_file)" ]] || die "No subscription URL found. Run install first."

  local url
  url=$(cat "$(sub_url_file)")
  info "Subscription URL: $url"

  section "Entering direct network mode"
  proxy_env_unset
  proxy_rules_down

  section "Re-generating config"
  rm -f "$(config_file)" 2>/dev/null || true
  generate_config "$url"

  section "Restarting transparent proxy"
  proxy_rules_up
  sleep 2

  systemctl is-active --quiet "$SERVICE_NAME" && ok "Service restarted" \
    || warn "Service may not be running"

  cmd_test
}
```

---

## 5. Проблема 3: upgrade бинаря тоже должен идти в direct network mode

### Текущее поведение

`cmd_upgrade()` получает latest version и скачивает бинарь до гарантированного снятия iptables/proxy env.

### Предлагаемая логика

1. Проверить установленную версию.
2. Перейти в direct network mode.
3. Получить latest release.
4. Скачать бинарь с retry/resume.
5. Обновить файл версии.
6. Перепатчить конфиг.
7. Запустить сервисы обратно.

### Обновлённый `cmd_upgrade()`

```bash
cmd_upgrade() {
  require_root
  [[ -f "${INSTALL_DIR}/version.txt" ]] || die "Not installed. Run install first."

  local current latest
  current=$(cat "${INSTALL_DIR}/version.txt")

  section "Entering direct network mode"
  proxy_env_unset
  proxy_rules_down

  latest=$(get_latest_version)

  if [[ "$current" == "$latest" ]]; then
    ok "Already on latest version: $current"
    proxy_rules_up
    return 0
  fi

  info "Upgrading: $current → $latest"

  section "Downloading new binary"
  download_binary "$latest"
  echo "$latest" > "${INSTALL_DIR}/version.txt"
  setcap 'cap_net_bind_service=+ep' "${INSTALL_DIR}/${BINARY_NAME}" 2>/dev/null || true

  section "Re-patching config"
  if [[ -f "$(config_file)" ]]; then
    patch_config "$(config_file)" "$(fixed_config)"
    chown root:"$HIDDIFY_USER" "$(fixed_config)"
    chmod 640 "$(fixed_config)"
  fi

  section "Restarting transparent proxy"
  systemctl daemon-reload
  proxy_rules_up
  sleep 2

  systemctl is-active --quiet "$SERVICE_NAME" && ok "Service restarted" \
    || warn "Service may not be running"

  cmd_test
}
```

---

## 6. Проблема 4: полное удаление должно сбрасывать proxy в окружении

### Что нужно удалять

`uninstall` должен гарантированно удалить:

- systemd-сервисы;
- iptables/ip6tables правила;
- сохранённые правила `netfilter-persistent`;
- `/etc/profile.d/hiddify-proxy.sh`;
- возможные proxy-переменные из текущего shell-процесса;
- `/opt/hiddify`;
- пользователя `hiddify-svc`.

### Дополнение к `cmd_uninstall()`

```bash
section "Removing proxy environment"
rm -f /etc/profile.d/hiddify-proxy.sh
proxy_env_unset

section "Flushing saved iptables rules"
iptables_del 2>/dev/null || true

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null || true
fi

if [[ -d /etc/iptables ]]; then
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
fi
```

Важно: `unset` влияет только на текущий процесс. Для уже открытых shell-сессий пользователь должен выполнить:

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
```

или просто перелогиниться.

---

## 7. Команды status/update/upgrade/test непосредственно после установки

### Вариант A — установленная CLI-команда `hcore`

Самый практичный вариант: при установке копировать `install.sh` в `/usr/local/sbin/hcore`.

```bash
install -m 755 "$0" /usr/local/sbin/hcore
```

После этого команды будут выглядеть так:

```bash
sudo hcore status
sudo hcore update
sudo hcore upgrade
sudo hcore test
sudo hcore uninstall
```

Плюсы:

- не нужно хранить `install.sh` в домашней директории;
- команды доступны системно;
- проще документировать;
- можно вызывать из cron/systemd timers.

### Вариант B — systemd ExecReload для update

Добавить в `/etc/systemd/system/hiddify.service`:

```ini
ExecReload=/usr/local/sbin/hcore update
```

Тогда обновление подписки:

```bash
sudo systemctl reload hiddify
```

Минус: `reload` для systemd обычно не ожидают как тяжёлую сетевую операцию. Поэтому лучше оставить `hcore update`.

### Вариант C — отдельные oneshot-сервисы

Создать:

- `hiddify-update.service`;
- `hiddify-upgrade.service`;
- `hiddify-test.service`.

Пример:

```ini
[Unit]
Description=Update Hiddify subscription

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hcore update
```

Команды:

```bash
sudo systemctl start hiddify-update
sudo systemctl start hiddify-upgrade
sudo systemctl start hiddify-test
```

Это удобно для automation, но для ручного управления `hcore update` проще.

---

## 8. Предлагаемая структура команд

```bash
hcore install --subscription-url <URL>
hcore update
hcore upgrade
hcore status
hcore test
hcore uninstall
hcore direct-on
hcore direct-off
```

Где:

- `direct-on` — временно снять iptables/proxy и вернуть прямой доступ;
- `direct-off` — снова включить transparent proxy;
- `update` и `upgrade` сами используют `direct-on`/`direct-off`.

---

## 9. Дополнительные предложения

### 9.1. Lock-файл

Чтобы нельзя было одновременно запустить `update` и `upgrade`:

```bash
LOCK_FILE="/run/hcore.lock"

with_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another hcore operation is already running"
  "$@"
}
```

В `main`:

```bash
with_lock cmd_update
```

### 9.2. Backup конфигов перед update

Перед перегенерацией:

```bash
backup_config() {
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "${INSTALL_DIR}/backup"
  cp -a "$(config_file)" "${INSTALL_DIR}/backup/current-config.${ts}.json" 2>/dev/null || true
  cp -a "$(fixed_config)" "${INSTALL_DIR}/backup/current-config.fixed.${ts}.json" 2>/dev/null || true
}
```

### 9.3. Rollback при неудачном update

Если новый конфиг не сгенерировался или сервис не поднялся — вернуть предыдущий `current-config.fixed.json`.

### 9.4. Health-check после старта

Проверять:

```bash
systemctl is-active hiddify
ss -lntup | grep -E '12334|12336|12337'
curl --max-time 20 https://api.ipify.org
```

### 9.5. Отдельный direct download для GitHub

Для GitHub API и GitHub Releases лучше всегда использовать прямой режим, без локального proxy env:

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    curl ...
```

---

## 10. Приоритетный roadmap

| Приоритет | Доработка | Зачем |
|---|---|---|
| P0 | `download_file()` с retry/resume/timeout | Исправить обрывы скачивания |
| P0 | `proxy_env_unset()` | Исключить влияние `/etc/profile.d/hiddify-proxy.sh` |
| P0 | `proxy_rules_down()` перед update/upgrade | Обновлять подписку и бинарь напрямую |
| P0 | Полный cleanup proxy/iptables при uninstall | Не оставлять систему в полупроксированном состоянии |
| P1 | Установка CLI `/usr/local/sbin/hcore` | Не запускать команды через локальный `install.sh` |
| P1 | `direct-on` / `direct-off` | Ручной аварийный режим |
| P1 | Backup + rollback config | Защита от битой подписки |
| P2 | oneshot systemd services | Удобство automation |
| P2 | lock-файл | Защита от параллельных операций |
| P2 | расширенный status/test | Быстрая диагностика |

---

## 11. Рекомендуемый минимальный патч

Минимально стоит сделать 5 изменений:

1. добавить `download_file()`;
2. заменить прямой `curl` в `download_binary()` на `download_file()`;
3. добавить `proxy_env_unset()`;
4. добавить `proxy_rules_down()` / `proxy_rules_up()`;
5. вызывать direct mode в `cmd_update()` и `cmd_upgrade()`.

После этого основные проблемы должны уйти:

- обрыв скачивания будет переживаться retry/resume;
- subscription update не будет зависеть от работающего transparent proxy;
- GitHub Releases будут скачиваться напрямую;
- uninstall будет безопаснее очищать окружение.
