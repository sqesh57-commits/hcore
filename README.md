# hiddify-core transparent proxy installer

Bash-скрипт для автоматической установки [hiddify-core](https://github.com/hiddify/hiddify-core) в режиме **transparent proxy** на Linux-серверах. Весь исходящий трафик машины автоматически проксируется через ваш VLESS/VMess/Trojan/Shadowsocks сервер — без необходимости настраивать каждое приложение вручную.

## Возможности

- Автоматическая загрузка последнего бинаря `hiddify-core` с GitHub Releases
- Более надёжное скачивание бинаря: retry, resume, таймауты, `.part` файл и отказ при пустом результате
- Определение архитектуры, libc, сетевого интерфейса и подсети — без хардкода
- Генерация конфига из subscription URL с автоматическим патчем [бага балансера](https://github.com/hiddify/hiddify-app/issues/2104)
- Перехват **всего** TCP-трафика через `iptables` (без изменения настроек приложений)
- Перехват DNS для предотвращения утечек
- Изолированный системный пользователь `hiddify-svc` — процесс не работает от root
- Автозапуск через `systemd`
- Сохранение правил `iptables` через `netfilter-persistent`
- Поддержка IPv6 (если есть публичный адрес)
- Команды `update` (новая подписка) и `upgrade` (новый бинарь)
- Полное удаление через `uninstall`

## Поддерживаемые платформы

| ОС | Архитектура |
|---|---|
| Debian 11 / 12 | x86\_64, arm64 |
| Ubuntu 22.04 / 24.04 | x86\_64, arm64 |
| Raspberry Pi OS | arm64 |

> Требует Python 3, curl, iptables. На чистых образах всё уже есть.

## Быстрый старт

```bash
# Скачать скрипт
curl -fsSL https://raw.githubusercontent.com/sqesh57-commits/hcore/main/install.sh -o install.sh
chmod +x install.sh

# Установить
sudo ./install.sh install --subscription-url "https://your-subscription-url/..."
```

После установки весь трафик сервера идёт через прокси. Проверка:

```bash
sudo ./install.sh test
# или через установленный wrapper
sudo hcore test
```

Ожидаемый результат — все три строки показывают IP вашего прокси-сервера, а не реальный IP машины:

```
  ✓  Via http_proxy env    : 2a13:d200:5:aa::1 (proxied)
  ✓  Direct IPv4 (iptables): 2a13:d200:5:aa::1 (proxied)
  ✓  As nobody (no env)    : 2a13:d200:5:aa::1 (proxied)
```

## Команды

> Текущая первая волна доработок затрагивает только надёжность скачивания бинаря. Логика proxy, iptables и lifecycle сервиса в этом шаге не меняется.

```bash
sudo ./install.sh install --subscription-url <URL> [--install-dir <DIR>]
```
Полная установка с нуля. Скачивает бинарь, генерирует конфиг, настраивает iptables и systemd.

```bash
sudo ./install.sh update
```
Обновить подписку — временно выключает transparent proxy для прямого доступа к сети, скачивает новый конфиг по сохранённому URL, патчит его, возвращает proxy-режим и перезапускает сервис.

```bash
sudo ./install.sh upgrade
```
Обновить бинарь `hiddify-core` до последней версии с GitHub Releases.

Во время `upgrade` скрипт временно выходит в direct mode, чтобы GitHub API и Releases не зависели от уже включённого transparent proxy.

Скачивание бинаря теперь идёт безопаснее:
- с retry при временных сбоях,
- с resume для частично скачанного файла,
- с ограничением по времени,
- через временный `.part` файл,
- с проверкой, что результат не пустой, перед заменой итогового архива.

```bash
sudo ./install.sh status
sudo hcore status
```
Показывает состояние сервиса, порты, правила iptables и текущий внешний IP.

```bash
sudo ./install.sh test
sudo hcore test
```
Проверяет что трафик идёт через прокси тремя способами: через env, через iptables redirect, от пользователя nobody.

```bash
sudo ./install.sh uninstall
```
Полное удаление: сервис, бинарь, конфиги, пользователь, proxy env profile, helper script и правила iptables с пересохранением очищенного persistent state.

## Опции установки

| Опция | По умолчанию | Описание |
|---|---|---|
| `--subscription-url` | — | URL подписки (обязательный) |
| `--install-dir` | `/opt/hiddify` | Директория установки |

## Что происходит под капотом

### Структура файлов после установки

```
/opt/hiddify/
├── hcore                     # установленная копия CLI-скрипта
├── hiddify-core              # бинарь
├── current-config.json       # конфиг сгенерированный из подписки
├── current-config.fixed.json # пропатченный конфиг (используется при запуске)
├── subscription.url          # сохранённый URL подписки
├── hcore-iptables.sh         # хелпер для systemd ExecStartPost/ExecStop
├── hiddify-core.log          # лог
└── version.txt               # текущая версия бинаря

/usr/local/sbin/hcore              # operational wrapper
/etc/systemd/system/hiddify.service
/etc/profile.d/hiddify-proxy.sh   # http_proxy env для новых сессий
```

### Схема работы трафика

```
Приложения (браузер, curl, apt...)
          │ TCP/UDP
          ▼
   iptables OUTPUT
   (цепочка HIDDIFY)
          │ REDIRECT → 127.0.0.1:12336
          ▼
   hiddify-core
   (redirect inbound :12336)
          │ зашифрованный трафик
          ▼
   Прокси-сервер (VLESS/VMess/Trojan...)
          │
          ▼
       Интернет
```

DNS-запросы перехватываются отдельно: `UDP/TCP :53 → 127.0.0.1:12337`

### Патч балансера

В `hiddify-core` v4.x есть [известный баг](https://github.com/hiddify/hiddify-app/issues/2104): при генерации конфига из подписки через `run -c URL` может создаваться `balancer` outbound с пустым полем `strategy`, что приводит к краш при старте через `srun`.

Скрипт автоматически:
1. Запускает `run -c URL` с таймаутом чтобы получить сгенерированный `current-config.json`
2. Удаляет сломанные `balancer` outbounds (с пустым `strategy`)
3. Исправляет ссылки на них в `selector`, `route.rules` и `route.final`
4. Добавляет недостающие inbounds (`mixed`, `redirect`, `dns`) если они не были сгенерированы
5. Сохраняет результат в `current-config.fixed.json`
6. Запускает `srun -c current-config.fixed.json` — минуя проблемный pipeline

### Изоляция процесса

`hiddify-core` запускается от пользователя `hiddify-svc` (системный, без shell, без home). В правилах iptables этот UID исключён из перехвата — это предотвращает routing loop когда сам прокси-процесс пытается отправить трафик.

## Ручная проверка после incremental changes

Для безопасного пошагового тестирования все рискованные изменения сначала проверяются на отдельном тестовом хосте.

Минимальная ручная проверка после install/upgrade/update:

```bash
systemctl status hiddify --no-pager
systemctl status hiddify-iptables --no-pager
ss -ltnup | grep -E '12334|12336|12337'
iptables -t nat -S
sudo hcore status
sudo hcore test
curl --noproxy '*' -4 https://ifconfig.me
curl https://ifconfig.me
```

Ожидаемый результат для шага со скачиванием: сетевое поведение не меняется, улучшается только надёжность скачивания.

Ожидаемый результат для шага с `update`/`upgrade`: перед сетевыми операциями скрипт временно выходит в direct mode, затем возвращает transparent proxy и проходит `test`.

Для `update` и `upgrade` скрипт также сохраняет runtime backup в `${INSTALL_DIR}/backup`. Если новый конфиг или запуск сервиса ломаются, скрипт откатывает runtime state и пытается вернуть сервис в рабочее состояние автоматически.

## Управление сервисом

```bash
# статус
systemctl status hiddify

# логи в реальном времени
journalctl -u hiddify -f

# перезапуск
systemctl restart hiddify

# остановить (iptables правила снимаются автоматически)
systemctl stop hiddify
```

## Известные ограничения

- **UDP трафик** (кроме DNS) не перехватывается через `iptables REDIRECT` — только TCP. Для полного UDP-перехвата нужен TUN-режим hiddify-core, что требует отдельной настройки.
- **IPv6**: правила добавляются только если на интерфейсе есть публичный IPv6 адрес (`scope global`). Link-local (`fe80::`) не считается.
- **Docker**: контейнеры с собственными network namespace не затрагиваются правилами `OUTPUT` — только трафик хоста. Для проксирования docker-трафика нужны правила в цепочке `FORWARD`.

## Требования

- Linux с systemd
- Python 3.x
- `curl`
- `iptables` / `ip6tables`
- `sudo` / root доступ
- Рабочий subscription URL для hiddify/sing-box

## Лицензия

MIT
