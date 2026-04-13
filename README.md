# hiddify-core transparent proxy installer

Bash-скрипт для автоматической установки [hiddify-core](https://github.com/hiddify/hiddify-core) в режиме **transparent proxy** на Linux-серверах. Весь исходящий трафик машины автоматически проксируется через ваш VLESS/VMess/Trojan/Shadowsocks сервер — без необходимости настраивать каждое приложение вручную.

## Возможности

- Автоматическая загрузка последнего бинаря `hiddify-core` с GitHub Releases
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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/install.sh -o install.sh
chmod +x install.sh

# Установить
sudo ./install.sh install --subscription-url "https://your-subscription-url/..."
```

После установки весь трафик сервера идёт через прокси. Проверка:

```bash
sudo ./install.sh test
```

Ожидаемый результат — все три строки показывают IP вашего прокси-сервера, а не реальный IP машины:

```
  ✓  Via http_proxy env    : 2a13:d200:5:aa::1 (proxied)
  ✓  Direct IPv4 (iptables): 2a13:d200:5:aa::1 (proxied)
  ✓  As nobody (no env)    : 2a13:d200:5:aa::1 (proxied)
```

## Команды

```bash
sudo ./install.sh install --subscription-url <URL> [--install-dir <DIR>]
```
Полная установка с нуля. Скачивает бинарь, генерирует конфиг, настраивает iptables и systemd.

```bash
sudo ./install.sh update
```
Обновить подписку — скачивает новый конфиг по сохранённому URL, патчит, перезапускает сервис.

```bash
sudo ./install.sh upgrade
```
Обновить бинарь `hiddify-core` до последней версии с GitHub Releases.

```bash
sudo ./install.sh status
```
Показывает состояние сервиса, порты, правила iptables и текущий внешний IP.

```bash
sudo ./install.sh test
```
Проверяет что трафик идёт через прокси тремя способами: через env, через iptables redirect, от пользователя nobody.

```bash
sudo ./install.sh uninstall
```
Полное удаление: сервис, бинарь, конфиги, пользователь, правила iptables.

## Опции установки

| Опция | По умолчанию | Описание |
|---|---|---|
| `--subscription-url` | — | URL подписки (обязательный) |
| `--install-dir` | `/opt/hiddify` | Директория установки |

## Что происходит под капотом

### Структура файлов после установки

```
/opt/hiddify/
├── hiddify-core              # бинарь
├── current-config.json       # конфиг сгенерированный из подписки
├── current-config.fixed.json # пропатченный конфиг (используется при запуске)
├── subscription.url          # сохранённый URL подписки
├── hcore-iptables.sh         # хелпер для systemd ExecStartPost/ExecStop
├── hiddify-core.log          # лог
└── version.txt               # текущая версия бинаря

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
