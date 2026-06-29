# Roadmap: hcore доработки

## Сравнение с hiddify-core

### Что уже есть в hiddify-core (НЕ дублировать):
- Multi-protocol support (VLESS, VMess, Trojan, Shadowsocks, WireGuard, etc.)
- Cross-platform (Android, macOS, Linux, Windows, iOS)
- Extension system
- Docker support
- OpenWrt support
- **Web UI** (порт 6756) — НЕ дублировать
- Subscription support (`run -c URL`)
- Свой installer.sh (простая установка бинаря)

### Наша ценность (ЧТО ДЕЛАЕМ):
- **Transparent proxy** — iptables rules для перехвата всего трафика
- **DNS leak prevention** — перехват DNS запросов
- **Process isolation** — hiddify-svc пользователь
- **Safety checks** — pre-flight проверки, rollback при ошибке
- **Subscription management** — замена, fallback, backup
- **CLI wrapper** — все команды через `hcore`
- **Health monitoring** — watchdog для proxy
- **Auto-update** — автоматическое обновление подписки

---

## Приоритет P0 — Критично

### 1. Замена подписки (`hcore subscription`)

**Проблема:** Сейчас для смены подписки нужно делать полный uninstall + install.

**Решение:** Добавить команду `hcore subscription <URL>`:

```bash
# Заменить подписку
hcore subscription "https://new-subscription-url/..."

# Показать текущую подписку
hcore subscription --show

# Проверить доступность подписки
hcore subscription --test
```

**Логика:**
1. Сохранить текущий конфиг как backup
2. Сгенерировать новый конфиг из новой подписки
3. Пропатчить конфиг
4. Перезапустить сервис
5. Проверить connectivity
6. При ошибке — откатить к предыдущему конфигу

### 2. Fallback подписки

**Проблема:** Если основная подписка недоступна, proxy перестаёт работать.

**Решение:** Хранить список подписок и автоматически переключаться:

```bash
# Добавить fallback подписку
hcore subscription --add-fallback "https://backup-subscription/..."

# Показать все подписки
hcore subscription --list

# Удалить fallback
hcore subscription --remove-fallback <index>
```

**Логика:**
- При старте проверять доступность основной подписки
- Если недоступна — пробовать fallback
- Если все недоступны — работать с последним успешным конфигом
- Логировать переключения

### 3. CLI wrapper (`/usr/local/sbin/hcore`)

**Проблема:** Сейчас установка идёт через `install.sh`, после установки `hcore` доступен не для всех команд.

**Решение:** Расширить CLI wrapper:

```bash
hcore install --subscription-url <URL>  # установка
hcore update                           # обновить подписку
hcore upgrade                          # обновить бинарь
hcore status                           # статус
hcore test                             # тест proxy
hcore uninstall                        # удаление
hcore subscription <URL>               # замена подписки
hcore subscription --show              # показать подписку
hcore subscription --test              # тест подписки
hcore direct-on                        # выключить proxy
hcore direct-off                       # включить proxy
hcore logs                             # показать логи
```

**Реализация:**
- CLI wrapper копируется при установке
- Все команды делегируются в install.sh с соответствующими аргументами

## Приоритет P1 — Важно

### 4. `direct-on` / `direct-off` команды

**Текущее состояние:** `proxy_direct_on()` и `proxy_direct_off()` уже есть в install.sh.

**Доработка:** Сделать доступными через CLI:

```bash
hcore direct-on    # остановить proxy, снять iptables, вернуть прямой доступ
hcore direct-off   # запустить proxy, вернуть iptables
```

**Логика:**
- `direct-on`: stop hiddify service, stop hiddify-iptables, unset proxy env
- `direct-off`: start hiddify-iptables, start hiddify service

### 5. Мониторинг здоровья proxy

**Проблема:** Нет способа узнать работает ли proxy в реальном времени.

**Решение:** Добавить watchdog:

```bash
hcore health       # проверить здоровье proxy
```

**Проверки:**
- Service active?
- Ports listening?
- Proxy IP != direct IP?
- No recent errors in log?
- Upstream server reachable?

### 6. Автообновление подписки

**Проблема:** Подписки имеют срок действия, нужно обновлять вручную.

**Решение:** Добавить cron/timer:

```bash
hcore auto-update --enable   # включить автообновление
hcore auto-update --disable  # выключить
hcore auto-update --status   # статус
```

**Логика:**
- Проверять подписку раз в N часов
- Если конфиг протухает — обновлять автоматически
- Уведомлять при ошибке

## Приоритет P2 — Желательно

### 7. Мульти-сервер поддержка

**Идея:** Управлять несколькими серверами через один CLI:

```bash
hcore remote add server1 192.168.1.100
hcore remote status server1
hcore remote update server1 --subscription-url <URL>
```

### 8. Статистика трафика

**Идея:** Собирать и показывать статистику:

```bash
hcore stats        # статистика за сегодня
hcore stats --week # за неделю
```

**Метрики:**
- Объём трафика
- Количество подключений
- Время работы
- Ошибки

---

## Текущий статус

| Функция | Статус | Приоритет | Дублирует hcore? |
|---------|--------|-----------|------------------|
| Установка | ✅ Готово | P0 | Нет |
| Update/Upgrade | ✅ Готово | P0 | Нет |
| Status/Test | ✅ Готово | P0 | Нет |
| Uninstall | ✅ Готово | P0 | Нет |
| DNS loop fix | ✅ Готово | P0 | Нет |
| Safety checks | ✅ Готово | P0 | Нет |
| Замена подписки | ✅ Готово | P0 | Нет |
| Fallback подписки | ✅ Готово | P0 | Нет |
| CLI wrapper | ✅ Готово | P0 | Нет |
| direct-on/off | ✅ Готово | P1 | Нет |
| Мониторинг (health) | ✅ Готово | P1 | Нет |
| Автообновление | ✅ Готово | P1 | Нет |
| Multi-server | 🔲 Идея | P2 | Нет |
| Статистика | 🔲 Идея | P2 | Нет |
| Web UI | ❌ НЕ ДЕЛАЕМ | — | Уже есть в hcore |
