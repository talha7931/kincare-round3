# KinCare Phase 5 — Final Android Offline-First Implementation Report

**Date:** 2026-11-24  
**Branch:** `feature/phase5`  
**Scope:** Flutter Android Phase 5 only. No Supabase schema/RLS or PWA changes were made in this implementation. No commit or push was made.

## 1. Executive summary

The Android Phase 5 implementation now prepares caregiver-specific offline data after successful online profile loading, stores cache/readiness information locally, paginates historical activity, retries failed media without needlessly downloading verified files again, and reports cache progress and states. SQLite is at version 4 with additive upgrades from older versions and enforced response/session and card/deck relationships. The existing sync outbox and sign-out protections remain in place; a table-name defect in sign-out cache cleanup was corrected.

Automated tests use temporary SQLite databases and do not connect to the production Supabase project. The 25-test suite and coverage run passed. A debug APK was built successfully. Real-device offline behavior, live Supabase cache preparation, and network/synchronization transitions still require the requested manual verification; no Android device or `adb` was available here.

## 2. Git safety and working tree

- Branch before and after: `feature/phase5`.
- The initial worktree already contained 15 modified tracked paths and 13 untracked entries, spanning Android, documentation, reports, and PWA work. Those changes were preserved.
- No branch switch, reset, clean, stash, commit, or push occurred.
- Final status remains on `feature/phase5`. The pre-existing PWA changes are still present and were not edited as part of this task.
- The only new report is this file; it is under the already-untracked `docs/reports/` directory.

## 3. Architecture changes

The Android client uses SQLite for structured local data and an owner-scoped sync outbox. Memory media is written under application support storage in a caregiver-specific directory. `cache_manifest` records readiness for decks, cards, media, and historical activity. Verified local files are checked before use; a missing or zero-byte file is not treated as cached.

`OfflineCachePreparation` runs after caregiver/profile data loads online and again after connectivity returns. It fetches the caregiver row, all authorized elderly profiles, historical activity and responses, then each profile's Memory Decks, cards, and referenced media. It preserves completed local work on retries. Its progress includes discovered card/media/history units and reports not-started, preparing, retrying, ready, partially-ready, failed, and waiting-for-network states.

The existing outbox continues to save sessions and responses transactionally and sync them under the current caregiver. Sync checks network-interface state, a lightweight internet probe, and an authenticated Supabase query separately. A PostgREST response is treated as proof that Supabase answered even if the query itself failed. Account changes invalidate the active sync generation and are checked before remote writes and local acknowledgement.

## 4. Detailed implementation

### Cache preparation and caregiver restoration

`OfflineCachePreparation.prepare` now uses stable ordered pagination for profiles, decks, cards, and historical sessions. It batches response lookups in groups of 100 session IDs. Preparation checks that the current authenticated user still matches the owner before caching results. It writes caregiver details to `caregiver_cache`; `CaregiverScreenState._loadData` reads that row in the offline fallback and restores the display name, with Auth metadata as a safe fallback.

Deck and card records remain keyed by caregiver and their existing identifiers. Per-card and per-media manifest entries report ready, partial, downloading, or failed states. A card without its required photograph is partial. A deck is ready only when all referenced media has a verified local path; otherwise it is partial or failed and the Memory Deck list displays an availability warning.

The caregiver status panel reports the current stage, completed and pending counts, failures, and retry action. Retry repeats metadata preparation but reuses media that already has a valid non-empty local file.

### Media storage and recovery

`OfflineStore.cacheMedia` writes into a temporary `.part-<timestamp>` file, flushes it, verifies non-empty content and optional expected byte length, then renames it into place. It leaves a previously valid copy intact until the replacement is verified. Handled failures remove the temporary file; old temporary files older than one hour are cleaned on a subsequent attempt for that asset. `cacheMediaIfNeeded` rechecks the manifest-backed file path and coalesces concurrent requests for the same caregiver/asset, avoiding duplicate downloads from preparation and Memory Deck loading.

`media_assets` currently does not expose an expected byte-size field in the selected metadata, so the preparation path cannot compare a cloud-provided expected size. The store supports the check when an expected size is supplied. Files are verified for existence and non-zero length; file-format decoding is not performed.

### Historical activity

`fetchAllPages` retrieves pages of 500 until the backend returns a short page. Sessions are ordered by `started_at DESC, id DESC`, which gives pagination a stable unique tie-breaker. The previous fixed 500-session limit is removed. Responses are fetched for batches of at most 100 session IDs and ordered by session, response index, and ID. Rows are stored with their caregiver and parent-session relationship; primary keys and replace semantics prevent duplicates on repeated preparation. Existing cached history is preserved if later pages or media fail.

### Connectivity and synchronization

`OfflineSyncService` distinguishes `noNetwork`, `noInternet`, `supabaseUnavailable`, offline, pending, syncing, failed, and synchronized states. `connectivity_plus` is used only for the network-interface state. A bounded HTTP 204 probe checks internet access, followed by a short authenticated Supabase query to check service reachability. Connectivity reconnection and app resume trigger a sync attempt. The existing generation counter is advanced on caregiver changes/sign-out; stale work is stopped before subsequent writes or local acknowledgement.

Synchronization still requires real-device and live-backend verification. The automated tests exercise local queue creation, retry state, acknowledgement state, and stale local acknowledgements, but do not send requests to Supabase.

### Cleanup and pending activity

The reproduced cleanup failure was an incorrect delete from table `outbox`; the actual SQLite table is `sync_outbox`. `clearSyncedCache` now queries and deletes the correct table. Its transaction removes only synced sessions and synced outbox rows. It protects any session with pending session/response work and leaves pending responses and original caregiver IDs intact. The sign-out flow in `main.dart` was not rewritten.

## 5. SQLite schema and migrations

The database is version **4**. A fresh database has 13 tables:

- Existing tables: `profiles`, `decks`, `cards`, `devices`, `media_files`, `sessions`, `responses`, `sync_outbox`, `sync_meta`.
- Cache/history tables: `caregiver_cache`, `cached_activity_sessions`, `cached_activity_responses`, `cache_manifest`.

Migrations are additive:

- Version 1 → 2 adds cache, caregiver, and historical activity tables.
- Version 2 → 3 rebuilds `responses` transactionally while copying all rows and adds `responses.session_id → sessions.id ON DELETE RESTRICT`.
- Version 3 → 4 rebuilds `cards` transactionally while copying all rows and adds the owner-scoped `cards(caregiver_id, deck_id) → decks(caregiver_id, id) ON DELETE CASCADE` relationship.

Foreign-key enforcement is enabled when SQLite opens. Both migrations check for orphan rows and stop with a descriptive error before changing the affected table if they find any; SQLite rolls back the upgrade transaction. Tests verify fresh initialization, version 1 migration, preservation of seeded session/response/deck/card/outbox rows, and rejection of orphan inserts. Session-to-profile and media-to-card relationships remain represented through owner-scoped IDs/metadata rather than new constraints; activity history must remain preservable even when a cached profile snapshot is refreshed or removed.

Session creation plus outbox insertion, response creation plus outbox insertion, cache history writes, and synced-cache cleanup remain transactional. A deliberate duplicate-response collision test proves the response batch and corresponding outbox write roll back together.

## 6. Cache and production data counts

The isolated fresh-schema test confirms 13 SQLite tables. The migration fixture confirms its seeded local rows survive. No installed application database was inspected, so actual caregiver/profile/deck/card/media/history counts on the device are **not available**. No production Supabase records were read or written.

## 7. Test results

Commands were run from `android_app/` unless noted:

| Command | Result |
|---|---|
| `flutter pub get` | Passed; dependencies resolved. 24 constrained packages have newer versions available. |
| `flutter test` | Passed: 25 tests. |
| `flutter test --coverage` | Passed: 25 tests; coverage output generated under `android_app/coverage/`. |
| `flutter analyze` | Exit 1 with 22 **info-only** diagnostics; no warnings or errors. Remaining infos are style notices and one deprecated form-field argument in existing screens. |
| `git diff --check` | Passed with exit 0; Git printed line-ending normalization warnings for existing CRLF/LF worktree files. |
| `flutter build apk --debug` | Passed. Gradle emitted Java native-access and future Kotlin Gradle Plugin compatibility warnings for `flutter_tts` and `record_android`; the APK still built. |

The 25 passing tests include 8 supplementary source checks, 6 isolated SQLite/cache/sync behavior cases, and the existing navigation/reporting tests. The 8 source checks only verify targeted implementation markers; they are not runtime proof. Behavioral tests use `sqflite_common_ffi`, temporary database files, and synthetic local media bytes; they do not connect to Supabase.

Behavioral coverage includes fresh schema creation, migration from version 1, record preservation, foreign-key enforcement, transaction rollback, local activity/outbox persistence, pending activity preservation, owner-scoped cache/history reads, pagination across 1,207 rows, media verification/reuse/concurrent request coalescing/stale `.part` cleanup, cache manifest/progress states, and retry/stale-ack outbox transitions.

Not tested automatically: authenticated cache preparation against a fake Supabase server, offline Auth SDK restoration, actual connectivity transitions, full remote sync/idempotency, UI sign-out, and caregiver switching during real network requests. No production backend was used for tests.

## 8. APK

- Build: succeeded; not installed.
- Path: `D:\kincare-round3\android_app\build\app\outputs\flutter-apk\app-debug.apk`
- File size: **225,322,837 bytes** (about 214.9 MiB).
- `adb` is unavailable in this environment, so physical-device installation and database inspection were not attempted.

## 9. Known limitations and remaining verification

- Run the manual online/offline/reconnect and caregiver-switch workflow on a physical Android device. The implementation has not passed device acceptance here.
- Confirm all real authorized Memory Deck assets download and render offline after process termination. Automated media tests use synthetic bytes.
- Confirm cache preparation against the configured Supabase project, including RLS visibility and historical page counts. No live Supabase request was made.
- Confirm actual server-side session/response idempotency and that activity appears once in caregiver history after reconnect. Local queue state is tested; remote writes are not.
- The media metadata selection has no expected byte-size field, so remote size comparison is unavailable. Local non-empty and optional supplied-size checks are implemented.
- The internet probe uses `connectivitycheck.gstatic.com/generate_204`; captive portals or networks that block this host may report internet unavailable even when some services are reachable. Test on the target network.
- Cache preparation resumes by re-running the authorized queries and reusing already verified media; it does not persist a page cursor.
- Analyzer exits non-zero because of 22 info-level notices. No warnings or errors were reported.

## 10. Physical-device manual test sequence

1. Install the APK manually; do not clear app data.
2. Sign in online with caregiver A and wait for the cache status to reach “Offline content ready.”
3. Use a caregiver account with at least two elderly profiles, multiple decks, image/audio assets, and more than 500 historical sessions if available. Confirm progress advances through profiles, history, cards, and media; use Retry after a controlled media failure.
4. Open each elderly profile and deck online once, then force-stop the app without clearing data.
5. Enable airplane mode and reopen. Confirm the caregiver name and only caregiver A's profiles remain visible.
6. Open a fully ready deck. Check photos and caregiver-recorded question/story audio. Confirm the Memory Story remains hidden until Reveal.
7. Play Odd One Out and Everyday Object Sorting offline. Complete each activity and confirm it appears in local activity history with pending sync state.
8. Force-stop and reopen offline. Confirm the profile, deck, game content, pending sessions, and responses remain.
9. Re-enable connectivity. Confirm the app reports syncing, then synchronized or specific failures. Retry only after the network/service is available.
10. Check caregiver activity history and Supabase manually; verify profile/activity relationships and that retry did not create duplicate sessions or responses.
11. Start an activity, sign out, and confirm pending activity is preserved while synced cache cleanup succeeds.
12. Sign in as caregiver B. Confirm no caregiver A profiles, decks, media, activity, or pending records appear or sync.
13. Sign back in as caregiver A and verify the preserved pending records can resume syncing.
14. If practical, revoke the enrolled device or remove profile access in a test environment; confirm affected records remain local and are not synchronized.

## 11. Final engineering assessment

**PARTIALLY COMPLETE —** the Android implementation and available automated checks are complete, but live Supabase and physical-device acceptance remain outstanding. No claim is made that offline restart, real media playback, connectivity recovery, or remote synchronization has passed on a device.

## 12. Files changed in this implementation

- `android_app/lib/offline_store.dart`
- `android_app/lib/offline_cache_preparation.dart`
- `android_app/lib/offline_sync.dart`
- `android_app/lib/elderly_memory_screen.dart`
- `android_app/lib/main.dart`
- `android_app/test/offline_store_behavior_test.dart`
- `android_app/test/phase5_defect_reproduction_test.dart`
- `docs/reports/PHASE5_FINAL_IMPLEMENTATION_REPORT.md`

No other agent or platform owner needs contract coordination: no Supabase schema/RLS or shared client contract changed.
