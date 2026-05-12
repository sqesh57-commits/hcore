# Merge summary for `dev -> main`

## Status

Recommended: **mergeable**

Basis:
- ключевые lifecycle сценарии реально прогнаны на отдельном стенде,
- найденные regressions и blockers были исправлены и перепроверены,
- итог зафиксирован в `TEST_RUN_2026-05-12.md`.

## What changed

### Runtime and networking
- safer binary download path,
- direct-mode networking for `update` / `upgrade`,
- runtime backup and rollback,
- better uninstall cleanup,
- recovery from partial install state.

### CLI and UX
- installed `hcore` wrapper in `/usr/local/sbin/hcore`,
- clearer `status` output,
- stronger `test` sanity checks,
- more user-friendly latest-version error handling.

### Process and release hygiene
- implementation checklist,
- pre-merge testing protocol,
- actual test run protocol,
- changelog.

## Commits in `dev` not in `main`

- `5417a63` Harden install recovery paths
- `322d4bd` Add pre-merge testing protocol
- `9e903b2` Harden runtime checks and locking
- `c3fcc5f` Install hcore operational wrapper
- `637b38c` Tighten uninstall cleanup
- `84514d6` Add runtime backup and rollback
- `b7bdcbf` Add direct mode for update and upgrade
- `d67c06e` Harden binary download path
- `d724d9f` Add hcore implementation checklist

## Remaining follow-ups after merge

- Review noisy upstream monitoring warnings in `hiddify-core` logs under healthy proxy state.
- Optionally continue with user-facing `direct-on` / `direct-off`, but only as a separate scoped change.

## Recommended merge steps

1. Re-read `TEST_RUN_2026-05-12.md` once before merge.
2. Merge `dev` into `main`.
3. Optionally tag this as the first stabilized post-hardening point.
