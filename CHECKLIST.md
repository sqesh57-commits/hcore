# hcore checklist

Цель: внедрять доработки маленькими безопасными кусками, каждый кусок отдельно тестировать на стенде и пушить в ветку `dev`.

## Правило работы

- Не смешивать много рискованных изменений в одном коммите.
- После каждого шага делать локальный review и тест на стенде `vm-de-ai-claw.cloud`.
- Все изменения сначала идут в ветку `dev`.
- Для сетевых изменений заранее фиксировать текущее состояние хоста: `iptables -t nat -S`, systemd units, `/opt/hiddify/`.

## Phase 0. Подготовка ветки и базовой дисциплины

- [ ] Создать и использовать ветку `dev` для всех доработок
- [ ] Настроить локальный workflow: маленькие коммиты, отдельные тесты на каждый кусок
- [ ] Зафиксировать минимальный smoke test сценарий для стенда
- [ ] Добавить в README короткую заметку, что опасные изменения тестируются только на отдельном хосте

## Phase 1. Safe download path

- [ ] Добавить `download_file()` с retry
- [ ] Добавить resume (`curl -C -` / `wget --continue`)
- [ ] Добавить `connect-timeout`, `max-time`, `retry-max-time`
- [ ] Добавить `.part` файл и проверку, что результат не пустой
- [ ] Перевести `download_binary()` на `download_file()`
- [ ] Прогнать тест скачивания бинаря на стенде

## Phase 2. Direct network mode for update/upgrade

- [ ] Добавить `proxy_env_unset()`
- [ ] Определить канонический способ выключения proxy state
- [ ] Определить канонический способ включения proxy state
- [ ] Переписать `cmd_update()` на safe direct mode
- [ ] Переписать `cmd_upgrade()` на safe direct mode
- [ ] Проверить, что после update сервис поднимается и трафик снова идёт через proxy
- [ ] Проверить, что после upgrade сервис поднимается и трафик снова идёт через proxy

## Phase 3. Backup and rollback

- [ ] Добавить backup текущих конфигов перед `update`
- [ ] Добавить backup перед `upgrade`, если меняется runtime config
- [ ] Добавить rollback, если новый конфиг не сгенерировался
- [ ] Добавить rollback, если сервис не поднялся после update/upgrade
- [ ] Проверить сценарий намеренно битого обновления на стенде

## Phase 4. Uninstall cleanup

- [ ] Усилить cleanup proxy env при uninstall
- [ ] Убедиться, что удаляются systemd units и helper script
- [ ] Убедиться, что `iptables` и `ip6tables` очищаются полностью
- [ ] Пересохранить пустое состояние persistent rules
- [ ] Проверить reinstall после uninstall на чистом состоянии

## Phase 5. Installed CLI

- [ ] Устанавливать CLI-команду `/usr/local/sbin/hcore`
- [ ] Обновить README под использование `hcore status/update/upgrade/test/uninstall`
- [ ] Проверить, что после установки команды работают без исходного `install.sh` из домашней директории

## Phase 6. Hardening and ergonomics

- [ ] Укрепить defensive checks в `patch_config()`
- [ ] Добавить lock-файл от параллельных операций
- [ ] Улучшить `status` так, чтобы было видно текущий режим и ключевые проблемы
- [ ] Улучшить `test` дополнительными sanity checks
- [ ] Подумать над `direct-on` / `direct-off` только после стабилизации базовой логики

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
