# hcore testing protocol

Цель: перед merge `dev -> main` прогнать не только технические smoke checks, но и реальные пользовательские сценарии, жизненные ситуации и edge cases, которые влияют на доверие к установщику.

Этот документ делится на две части:
- **Checklist сценариев** — что именно надо проверить
- **Протокол прогона** — что именно фиксировать по результатам

---

## 1. Принципы тестирования

- Тестируем на отдельном disposable стенде, а не на основной машине.
- Каждый сценарий должен иметь понятный ожидаемый результат глазами пользователя.
- Для сетевых сценариев важнее не только exit code, но и:
  - сохранился ли доступ к машине,
  - поднялся ли сервис,
  - идёт ли трафик через proxy,
  - остался ли пользователь в понятном recoverable состоянии.
- Если сценарий ломает SSH во время install/restart, это не автоматически fail, если:
  - хост возвращается,
  - сервис поднимается,
  - `hcore status` и `hcore test` после reconnect успешны.
- Каждый fail должен классифицироваться:
  - blocker before merge
  - acceptable limitation
  - follow-up improvement

---

## 2. Минимальный артефакт по каждому прогону

Для каждого сценария фиксировать:

- ID сценария
- дата/время
- хост / ОС / архитектура
- версия коммита
- входные условия
- шаги
- ожидаемый результат
- фактический результат
- verdict: PASS / FAIL / PARTIAL
- notes / follow-up

---

## 3. Базовые пользовательские сценарии

### U1. Чистая установка по подписке

**Зачем:** основной happy path глазами пользователя.

Проверить:
- `install --subscription-url ...`
- создаётся пользователь `hiddify-svc`
- создаётся `/opt/hiddify`
- создаются systemd units
- создаётся `/usr/local/sbin/hcore`
- сервисы `hiddify` и `hiddify-iptables` active
- `hcore status` показывает здоровое summary
- `hcore test` успешен
- внешний IP через proxy отличается от IP машины

### U2. Повторный install поверх существующей установки

**Зачем:** пользователь часто повторно запускает install вместо update.

Проверить:
- повторный `install --subscription-url ...`
- нет ли разрушения runtime state
- остаётся ли рабочим wrapper `hcore`
- не дублируются ли iptables rules
- сервис после повторного install остаётся рабочим

### U3. Update действующей подписки

**Зачем:** самый жизненный ежедневный сценарий.

Проверить:
- `hcore update`
- direct mode временно включается и затем выключается
- backup создаётся
- сервис после update active
- `hcore test` успешен
- нет утечки трафика в direct после завершения

### U4. Upgrade бинаря

**Зачем:** пользователь хочет обновить binary без ручного переустановления.

Проверить:
- `hcore upgrade`
- direct mode используется только на время сетевых операций
- бинарь обновляется корректно
- service restart успешен
- `hcore test` успешен

### U5. Uninstall

**Зачем:** пользователь должен уметь безопасно откатиться полностью.

Проверить:
- `hcore uninstall`
- удаляются units
- удаляется `/opt/hiddify`
- удаляется `/usr/local/sbin/hcore`
- удаляется `/etc/profile.d/hiddify-proxy.sh`
- удаляются `HIDDIFY` правила
- persistent rules пересохраняются пустыми
- пользователь `hiddify-svc` удаляется

### U6. Reinstall после uninstall

**Зачем:** UX восстановления после полного удаления.

Проверить:
- uninstall
- затем чистый install по той же подписке
- system возвращается в полностью рабочее состояние

---

## 4. Сценарии устойчивости и отказов

### R1. Битая генерация конфига во время update

Проверить:
- намеренно сломанный сценарий после `generate_config`
- rollback восстанавливает runtime state
- сервис остаётся рабочим
- proxy после rollback работает

### R2. Битый restart после update/upgrade

Проверить:
- искусственно создать ситуацию, где сервис не поднимется
- rollback должен вернуть прошлую конфигурацию/бинарь
- после rollback `hcore test` снова успешен

### R3. Сбой скачивания бинаря

Проверить:
- временно недоступный URL / сетевой fail
- retry/resume работают ожидаемо
- не остаётся пустой итоговый архив
- существующий рабочий binary не уничтожается неатомарно

### R4. Параллельный запуск команд

Проверить:
- одна операция держит lock
- вторая команда получает понятную ошибку
- lock не остаётся навсегда после завершения нормальной команды

### R5. Переподключение после временной потери SSH

Проверить:
- install/update/restart может кратко порвать SSH
- после reconnect состояние консистентно
- service active
- `hcore status` и `hcore test` успешны

---

## 5. UX-сценарии и человеческие ошибки

### X1. Запуск без аргументов

Проверить:
- `./install.sh`
- `hcore`
- показывается понятный usage

### X2. Неизвестная команда

Проверить:
- `hcore unknown-command`
- пользователь получает понятную ошибку

### X3. Install без subscription URL

Проверить:
- `hcore install`
- ошибка понятная и сразу говорит, чего не хватает

### X4. Команда из wrapper без исходного `install.sh` рядом

Проверить:
- запускать только `hcore status/test/update/uninstall`
- убедиться, что ничего не зависит от текущего cwd

### X5. Повторный uninstall

Проверить:
- uninstall на уже удалённой системе
- поведение должно быть максимально предсказуемым и неопасным

### X6. Status на сломанной/неполной установке

Проверить:
- отсутствует config
- сервис inactive
- wrapper есть, но runtime broken
- `status` должен подсветить проблему, а не просто молча показать куски состояния

---

## 6. Сетевые и средовые сценарии

### N1. IPv4-only host

Проверить:
- стандартный install/test на хосте без публичного IPv6
- ip6tables корректно пропускаются без ложного fail

### N2. Host с публичным IPv6

Проверить:
- создаются IPv6 правила
- uninstall корректно снимает и их

### N3. Host после reboot

Проверить:
- reboot
- `hiddify` и `hiddify-iptables` возвращаются
- persistent rules поднимаются корректно
- `hcore test` после reboot успешен

### N4. Host с уже загрязнённым iptables state

Проверить:
- старые/дублированные правила
- install/uninstall не оставляют state ещё грязнее
- uninstall действительно вычищает duplicate matching rules

### N5. Host с частично старой установкой

Проверить:
- старый install dir
- старые units
- старый profile
- убедиться, что install/uninstall/update ведут себя предсказуемо

---

## 7. Сценарии данных и артефактов

### D1. Backup artifacts после update/upgrade

Проверить:
- создаётся timestamped backup
- обновляется `backup/latest`
- backup содержит:
  - binary
  - version
  - config
  - fixed config
  - subscription URL

### D2. Права доступа

Проверить:
- права на `current-config.fixed.json`
- права на `subscription.url`
- права на `data/`
- права на log file
- права на wrapper `/usr/local/sbin/hcore`

### D3. Логи и диагностируемость

Проверить:
- при fail пользователь видит понятную ошибку
- `journalctl -u hiddify` помогает понять состояние
- `hcore status` даёт достаточно контекста для first-line debugging

---

## 8. Предмерджевый master-checklist

Это тот чеклист, который надо пройти перед merge `dev -> main`.

### A. Happy path
- [ ] Чистый install PASS
- [ ] `hcore status` PASS
- [ ] `hcore test` PASS
- [ ] Update PASS
- [ ] Upgrade PASS
- [ ] Uninstall PASS
- [ ] Reinstall PASS

### B. Recovery
- [ ] Broken update rollback PASS
- [ ] Broken restart rollback PASS
- [ ] Download failure handling PASS
- [ ] Lock contention PASS

### C. UX
- [ ] Usage/help PASS
- [ ] Unknown command PASS
- [ ] Install without URL PASS
- [ ] Wrapper works independently PASS
- [ ] Status on degraded state PASS

### D. Environment
- [ ] Reboot persistence PASS
- [ ] IPv4-only behavior PASS
- [ ] Dirty state cleanup PASS
- [ ] Old install compatibility checked

### E. Artifacts
- [ ] Backup artifacts verified
- [ ] Permissions verified
- [ ] Docs match actual behavior

---

## 9. Шаблон протокола прогона

Ниже шаблон, который можно копировать для каждой большой тестовой сессии.

```markdown
# Test run protocol

- Date:
- Commit:
- Branch:
- Host:
- OS:
- Kernel:
- Architecture:
- Subscription source:

## Scenario results

| ID | Scenario | Result | Notes |
|---|---|---|---|
| U1 | Clean install | PASS/FAIL/PARTIAL | |
| U2 | Reinstall over existing install | PASS/FAIL/PARTIAL | |
| U3 | Update | PASS/FAIL/PARTIAL | |
| U4 | Upgrade | PASS/FAIL/PARTIAL | |
| U5 | Uninstall | PASS/FAIL/PARTIAL | |
| U6 | Reinstall after uninstall | PASS/FAIL/PARTIAL | |
| R1 | Broken update rollback | PASS/FAIL/PARTIAL | |
| R2 | Broken restart rollback | PASS/FAIL/PARTIAL | |
| R3 | Download failure handling | PASS/FAIL/PARTIAL | |
| R4 | Lock contention | PASS/FAIL/PARTIAL | |
| R5 | SSH reconnect resilience | PASS/FAIL/PARTIAL | |
| X1 | No-arg usage | PASS/FAIL/PARTIAL | |
| X2 | Unknown command | PASS/FAIL/PARTIAL | |
| X3 | Install without URL | PASS/FAIL/PARTIAL | |
| X4 | Wrapper independence | PASS/FAIL/PARTIAL | |
| X5 | Repeat uninstall | PASS/FAIL/PARTIAL | |
| X6 | Status on degraded state | PASS/FAIL/PARTIAL | |
| N1 | IPv4-only host | PASS/FAIL/PARTIAL | |
| N2 | IPv6 host | PASS/FAIL/PARTIAL | |
| N3 | Reboot persistence | PASS/FAIL/PARTIAL | |
| N4 | Dirty iptables state | PASS/FAIL/PARTIAL | |
| N5 | Partial old install | PASS/FAIL/PARTIAL | |
| D1 | Backup artifacts | PASS/FAIL/PARTIAL | |
| D2 | Permissions | PASS/FAIL/PARTIAL | |
| D3 | Diagnostics/logs | PASS/FAIL/PARTIAL | |

## Merge recommendation

- Ready to merge: yes / no
- Blocking issues:
- Follow-ups after merge:
```

---

## 10. Практическая рекомендация по следующему шагу

Лучший следующий шаг перед merge:

1. Не мерджить сразу.
2. Пройти этот protocol на одном полном прогоне.
3. Зафиксировать результаты в отдельном файле, например `TEST_RUN_YYYY-MM-DD.md`.
4. Отдельно выписать blockers и acceptable limitations.
5. Только после этого решать merge `dev -> main`.
