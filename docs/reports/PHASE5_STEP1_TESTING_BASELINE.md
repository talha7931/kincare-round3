# Phase 5 Step 1 — Flutter Testing Baseline

**Date:** 2026-11-24  
**Branch:** `feature/phase5`  
**Scope:** Android Flutter tests only. No production code, PWA files, Supabase data/schema, or authentication configuration changed. Existing worktree edits were preserved. Added tests, a test-only SQLite FFI dependency, and this report; no commit or push.

## Summary

The eight original Phase 5 defect checks all execute and pass as *source-text checks*. They establish that the searched code markers are currently present/absent, but do not execute the functions under test. Several use brittle string/sub-string assumptions and are not behavioral reproductions.

One isolated SQLite behavior test was added. It creates a temporary version-1 SQLite database, upgrades it through the actual `OfflineStore` opening path, and verifies existing pending data survives, transactions roll back, and owner-scoped cache/history rows are isolated. No installed application database or production Supabase was accessed.

The original baseline ran 20 tests successfully before pending-cache cleanup was added to the SQLite scenario. The extended behavior test now exposes a cleanup defect: both full test commands fail at `clearSyncedCache` because it issues a delete against nonexistent table `outbox` instead of the created `sync_outbox`. This is intentionally left unfixed in the testing step. `flutter analyze` exits **1** with 32 informational diagnostics and no analyzer errors. None of these results proves real Android offline operation.

## Test environment and commands

- Flutter project: `D:\kincare-round3\android_app`.
- Added test-only `sqflite_common_ffi` to execute SQLite against a temporary FFI database. No production dependency was added. Pub resolution added the FFI/native SQLite support packages to `pubspec.lock`.
- Tests use generated temporary directory `kincare_phase5_sqlite_*`; teardown closes and removes only that test directory.
- No credentials, tokens, production records, or live Supabase writes were used.
- `adb` is unavailable; physical device tests were not run.

## Exact command results

| Command | Result |
|---|---|
| `flutter test` | Exit 1; 19 tests pass before the SQLite scenario fails on missing table `outbox`. The 8 source checks and 11 pre-existing tests pass. |
| `flutter test --coverage` | Exit 1; same SQLite cleanup failure. Coverage run cannot be treated as a successful baseline. |
| `flutter analyze` | Exit 1; **32 info diagnostics**, all curly-brace style notices except one deprecated `DropdownButtonFormField.value`; no analyzer errors. |
| `git diff --check` | Exit 0; Git emitted line-ending conversion warnings on pre-existing modified files. |

## Review of the eight source-audit tests

All eight execute successfully in `phase5_defect_reproduction_test.dart`; each passing result means its textual assertion matched the inspected current source. None invokes the corresponding production function.

| Test | Production target and defect indicated | Quality assessment |
|---|---|---|
| History fetch capped at 500 | `OfflineCachePreparation.prepare`: query calls `.limit(500)` without pagination. | Confirms a literal limit. `isNot(contains('range('))` scans the entire file and can be fooled by an unrelated string or pagination implemented through a helper; brittle, static only. |
| Caregiver details cached but not restored | `OfflineStore.cacheCaregiver`; `CaregiverScreenState._loadData`: offline fallback calls `readProfiles` but does not load caregiver cache. | The substring boundaries currently resolve to `_loadData` and `_loadProfiles`, so the check runs against the intended fallback. It can break on a rename/reordering, and its `caregiver_cache` absence check only scans this method body. Static only. |
| Progress omits cards/media | `OfflineCachePreparation.prepare`: `total` increases for profiles and decks, not card/media work. | Direct string-presence/absence assertions across the class; overly broad and can miss helper-based progress accounting. Static only. |
| Partial deck not consulted | `OfflineCachePreparation.prepare` records `partial`; `ElderlyMemoryScreen` does not query `cacheItems`. | Presence/absence of method name is insufficient: viewer could check another manifest API or a model. Static only. |
| Reachability classification conflation | `OfflineSyncService.syncNow` and `snapshot`: connectivity-derived `_online` assignment does not update `_hasNetwork`; failed internet probe also sets `_supabaseReachable=false`, confusing no internet with Supabase outage. | Extracted ranges are valid today, but depend on exact marker text. The assertion confirms specific assignments, not resulting UI state. Static only. |
| No SQLite foreign keys | `OfflineStore.database` DDL has no `FOREIGN KEY` or `REFERENCES`. | Whole-file substring absence is weak and may match comments/strings; the DDL itself was reviewed and currently has no FK declarations. No runtime integrity test in this source test. |
| Media retry redownloads | `OfflineCachePreparation.prepare`: media loop downloads without checking `OfflineStore.mediaPath` first. | Test extracts a fixed 450-character window around `.download(path)`. This is especially brittle; edits can move the relevant code outside the window. It does not execute a retry. |
| Owner switch does not invalidate running generation | `OfflineSyncService.initialize`: assigns `_ownerId` but does not increment `_syncGeneration` when changing owners; `stopForSignOut` does increment it. | Substring extraction currently covers the intended method, but only checks literal code. It does not orchestrate an in-flight request or prove whether wrong-owner upload occurs. Static only. |

## Behavioral test added

`offline_store_behavior_test.dart` creates an isolated temporary v1 database using `sqflite_common_ffi`, seeds a pre-existing completed session and pending outbox record, then opens it using the production singleton. It verifies:

- The v1→v2 migration adds the expected cache/history tables and preserves the seeded session/outbox row.
- `createSession` and `saveResponses` persist local records and queue entries.
- A deliberate duplicate response-ID conflict after an earlier valid insert rolls back the transaction: neither the first response nor its queue row remains.
- Cache manifest states are scoped by caregiver.
- Cached history/response reads return only rows for the requested caregiver/profile/session.

This is genuine local SQLite behavior against the production store implementation. Migration, existing-row retention, transactions/rollback, manifest scoping, caregiver/history filtering, deck/card reads and media-path verification pass. The final pending cleanup assertion fails because production cleanup targets nonexistent `outbox`; therefore synced-cache deletion and pending preservation during that cleanup cannot complete. This is also a concrete defect in the sign-out cleanup path. It does not test Android SQLite plugin behavior or process-restart persistence on a device.

## Coverage gaps and safely untestable areas

The suite still has no behavioral tests for pagination beyond 500 sessions, caregiver startup restoration, cache preparation completeness, media retry/reuse decisions, internet/Supabase reachability, sync idempotency/retry/interruption, auth restoration/expiry, sign-out UI, or in-flight account switching. `OfflineCachePreparation` and `OfflineSyncService` are coupled to `SupabaseClient`, connectivity plugins, and concrete network/storage calls; no mock HTTP/Supabase service is installed. Safe functional testing of those flows needs injectable service boundaries and a fake Supabase/API/storage server. These remain **NOT TESTED**, not passing. Local SQLite tests do verify caregiver-scoped cache/history reads, and the media path lookup itself, but they do not prove UI restoration or download reuse.

The isolated SQLite behavior test covers transaction rollback and migration but not `cacheMedia`, since it uses `path_provider`'s application support directory. No real `media_assets` or files were created. The original 8 tests are source audit alarms, not regression tests for end-to-end behavior.

## Current defect status from inspection

All eight listed conditions are still represented in production source at this baseline. This test-only step did not fix them. The source checks pass because they confirm the current defect markers. The expanded SQLite behavior test passes its migration, transaction, and scoped-cache assertions, then fails while reproducing the pending-cleanup table-name defect.

## Working tree and preservation

Branch remained `feature/phase5`. Existing modified/untracked application and PWA files were preserved. This step added only:

- `android_app/test/phase5_defect_reproduction_test.dart`
- `android_app/test/offline_store_behavior_test.dart`
- Test-only dev dependency `sqflite_common_ffi` in `android_app/pubspec.yaml` and its lockfile resolution.
- This report.

No source fixes, PWA changes, schema/RLS/auth changes, commits, or pushes were made.
