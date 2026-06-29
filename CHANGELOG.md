# Changelog

## 2026-06-29

### Added
- Pre-flight network validation: DNS resolution, internet connectivity, subscription URL reachability, upstream server resolution
- Rollback mechanism: automatic cleanup on installation failure
- Post-install connectivity verification: tests proxy connection after install
- Connection check section in `status` command: shows proxy IP vs direct IP
- Subscription status display in `status` command: shows masked URL and config age
- `diagnose.sh` for safe subscription testing without enabling proxy
- `check-connection.sh` for connection diagnostics
- DNS UID bypass: hiddify-svc DNS queries bypass redirect to prevent DNS loop

### Fixed
- DNS loop: hiddify-core could not resolve upstream server because DNS queries were redirected through itself. Fixed by adding UID-based RETURN rules in OUTPUT chain before DNS REDIRECT rules
- Lock file permission error: changed LOCK_DIR from `/run/lock` to `/tmp` for reliable permissions
- `lf: unbound variable` error in lock trap: changed from local variable to global `_HCORE_LOCK_FILE`
- `cache.db: permission denied`: added ownership fix in `setup_dirs()` for existing cache files
- Uninstall: removed duplicate `/etc/profile.d/hiddify-proxy.sh` cleanup, added lock file cleanup, added post-uninstall verification
- install.sh now cleans stale iptables rules from previous installations before config generation

### Changed
- Better error messages for network failures during installation
- `status` command now shows subscription URL (masked), config age, and proxy connectivity
- `test` command output includes connection status

## Unreleased (from previous work)

### Added
- Добавлен `CHECKLIST.md` для пошаговой безопасной доработки и стендового тестирования.
- Добавлен установленный operational wrapper `/usr/local/sbin/hcore`.
- Добавлены runtime backup artifacts для `update` и `upgrade`.
- Добавлен pre-merge testing protocol (`TESTING_PROTOCOL.md`).
- Добавлен фактический протокол прогона (`TEST_RUN_2026-05-12.md`).

### Changed
- Укреплён путь скачивания бинаря: retry, resume, timeouts, `.part` file, проверка непустого результата.
- `update` и `upgrade` теперь умеют временно выходить в direct mode для сетевых операций и затем возвращать transparent proxy.
- `update` и `upgrade` теперь используют backup/rollback при проблемах с regenerated config или service health.
- `uninstall` теперь чище убирает proxy env, helper script, persistent iptables state и duplicate matching rules.
- `status` теперь показывает summary по runtime state и ключевые предупреждения.
- `test` теперь включает дополнительные sanity checks по service state, redirect port и OUTPUT → HIDDIFY.
- Установочный flow теперь лучше восстанавливается из partial install state, если `hiddify-iptables` активен, а основной сервис не поднят.
- Ошибки получения latest version из GitHub API теперь более дружелюбны и не протекают сырым Python traceback.

### Fixed
- Исправлен сценарий, где обновление подписки ломалось при активном transparent proxy.
- Исправлен rollback path для намеренно битого `fixed_config` во время `update`.
- Исправлен wrapper `hcore`, чтобы корректно прокидывались аргументы `"$@"`.
- Исправлен false-negative на пути `upgrade`, когда версия уже latest и proxy test запускался слишком рано после возврата proxy state.
- Исправлен recovery path для partial old install, чтобы reinstall не оставлял stale transparent proxy state без рабочего сервиса.
