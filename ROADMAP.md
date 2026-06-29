# Roadmap: hcore доработки

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
hcore config                           # показать конфиг
```

**Реализация:**
- CLI wrapper копируется при установке
- Все команды делегируются в install.sh с соответствующими аргументами
- Добавить tab-completion для bash

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
- Сохранять состояние для восстановления

### 5. Мониторинг здоровья proxy

**Проблема:** Нет способа узнать работает ли proxy в реальном времени.

**Решение:** Добавить watchdog:

```bash
hcore health       # проверить здоровье proxy
hcore watch        # мониторинг в реальном времени
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

### 7. Web UI

**Идея:** Минимальный веб-интерфейс для управления:

- Просмотр статуса
- Замена подписки
- Просмотр логов
- Включение/выключение proxy

**Реализация:**
- Python/Go сервер на порту 8080
- Простой HTML/CSS/JS фронтенд
- Auth через пароль или token

### 8. Мульти-сервер поддержка

**Идея:** Управлять несколькими серверами через один CLI:

```bash
hcore remote add server1 192.168.1.100
hcore remote status server1
hcore remote update server1 --subscription-url <URL>
```

### 9. Статистика трафика

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

## Приоритет P3 — Идеи

### 10. WireGuard over VLESS

**Идея:** Использовать VLESS как транспорт для WireGuard:

- Более стабильное соединение
- Поддержка UDP
- Лучшая производительность

### 11. Load balancing

**Идея:** Распределять трафик между несколькими серверами:

```bash
hcore balance add server1 server2 server3
hcore balance status
```

### 12. Docker интеграция

**Идея:** Проксировать трафик Docker контейнеров:

```bash
hcore docker enable    # включить proxy для Docker
hcore docker disable   # выключить
```

---

## Текущий статус

| Функция | Статус | Приоритет |
|---------|--------|-----------|
| Установка | ✅ Готово | P0 |
| Update/Upgrade | ✅ Готово | P0 |
| Status/Test | ✅ Готово | P0 |
| Uninstall | ✅ Готово | P0 |
| DNS loop fix | ✅ Готово | P0 |
| Safety checks | ✅ Готово | P0 |
| Замена подписки | 🔲 Не начато | P0 |
| Fallback подписки | 🔲 Не начато | P0 |
| CLI wrapper | 🔲 Частично | P0 |
| direct-on/off | 🔲 Не начато | P1 |
| Мониторинг | 🔲 Не начато | P1 |
| Автообновление | 🔲 Не начато | P1 |
| Web UI | 🔲 Идея | P2 |
| Multi-server | 🔲 Идея | P2 |
| Статистика | 🔲 Идея | P2 |
