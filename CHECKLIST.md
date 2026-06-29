# hcore checklist

Цель: внедрять доработки маленькими безопасными кусками, каждый кусок отдельно тестировать на стенде и пушить в ветку `dev`.

## Правило работы

- Не смешивать много рискованных изменений в одном коммите.
- После каждого шага делать локальный review и тест на стенде `vm-de-ai-claw.cloud`.
- Все изменения сначала идут в ветку `dev`.
- Для сетевых изменений заранее фиксировать текущее состояние хоста: `iptables -t nat -S`, systemd units, `/opt/hiddify/`.

## Phase 0. Подготовка ветки и базовой дисциплины

- [x] Создать и использовать ветку `dev` для всех доработок
- [x] Настроить локальный workflow: маленькие коммиты, отдельные тесты на каждый кусок
- [x] Зафиксировать минимальный smoke test сценарий для стенда
- [x] Добавить в README короткую заметку, что опасные изменения тестируются только на отдельном хосте

## Phase 1. Safe download path

- [x] Добавить `download_file()` с retry
- [x] Добавить resume (`curl -C -` / `wget --continue`)
- [x] Добавить `connect-timeout`, `max-time`, `retry-max-time`
- [x] Добавить `.part` файл и проверку, что результат не пустой
- [x] Перевести `download_binary()` на `download_file()`
- [ ] Прогнать тест скачивания бинаря на стенде

## Выявленные реальные кейсы на стенде

- [x] Подтверждён реальный failure mode: подписка меняется, а `hcore` не может обновиться при активном transparent proxy
- [x] Подтверждён дополнительный runtime кейс: `initialize cache-file: open cache.db: permission denied`
- [x] Для каждого такого кейса фиксировать, относится ли он к текущей фазе или идёт отдельным follow-up
- [x] Update failure через активный proxy относится к текущей Phase 2
- [x] `cache.db permission denied` выглядит отдельным runtime follow-up, не обязательным условием для direct-mode фикса

## Phase 2. Direct network mode for update/upgrade

- [ ] Добавить `proxy_env_unset()`
- [x] Определить канонический способ выключения proxy state
- [x] Определить канонический способ включения proxy state
- [x] Переписать `cmd_update()` на safe direct mode
- [x] Переписать `cmd_upgrade()` на safe direct mode
- [x] Проверить, что после update сервис поднимается и трафик снова идёт через proxy
- [ ] Проверить, что после upgrade сервис поднимается и трафик снова идёт через proxy

## Phase 3. Backup and rollback

- [x] Добавить backup текущих конфигов перед `update`
- [x] Добавить backup перед `upgrade`, если меняется runtime config
- [x] Добавить rollback, если новый конфиг не сгенерировался
- [x] Добавить rollback, если сервис не поднялся после update/upgrade
- [x] Проверить сценарий намеренно битого обновления на стенде

## Phase 4. Uninstall cleanup

- [x] Усилить cleanup proxy env при uninstall
- [x] Убедиться, что удаляются systemd units и helper script
- [x] Убедиться, что `iptables` и `ip6tables` очищаются полностью
- [x] Пересохранить пустое состояние persistent rules
- [x] Проверить reinstall после uninstall на чистом состоянии

## Phase 5. Installed CLI

- [x] Устанавливать CLI-команду `/usr/local/sbin/hcore`
- [x] Обновить README под использование `hcore status/update/upgrade/test/uninstall`
- [x] Проверить, что после установки команды работают без исходного `install.sh` из домашней директории

## Phase 6. Hardening and ergonomics

- [x] Укрепить defensive checks в `patch_config()`
- [x] Добавить lock-файл от параллельных операций
- [x] Улучшить `status` так, чтобы было видно текущий режим и ключевые проблемы
- [x] Улучшить `test` дополнительными sanity checks
- [ ] Подумать над `direct-on` / `direct-off` только после стабилизации базовой логики

## Предмерджевое расширенное тестирование

- [ ] Пройти сценарии из `TESTING_PROTOCOL.md`
- [ ] Оформить отдельный протокол фактического прогона
- [ ] Разделить результаты на blockers / acceptable limitations / follow-ups
- [ ] Принимать решение о merge `dev -> main` только после полного прогона

## Smoke test после каждого сетевого изменения

- [ ] `systemctl status hiddify --no-pager`
- [ ] `systemctl status hiddify-iptables --no-pager`
- [ ] `ss -ltnup | grep -E '12334|12336|12337'`
- [ ] `iptables -t nat -S`
- [ ] `hcore status` или `sudo ./install.sh status`
- [ ] `hcore test` или `sudo ./install.sh test`
- [ ] Проверка внешнего IP напрямую и через proxy

## Отдельно не забыть

- [ ] Не дублировать одновременно ручное снятие правил и systemd lifecycle без явной причины
- [ ] Не тащить слишком рано user-facing `direct-on/direct-off`, пока не стабилизированы update/upgrade
- [ ] Не перегружать один PR несколькими сетевыми изменениями сразу
