# KinCare Phase 6 — Architecture Audit and Implementation Plan

**Date:** 2026-11-24  
**Branch:** `feature/phase5`  
**Scope:** Android Flutter architecture audit and planning only. No application source, dependencies, Android build configuration, Supabase schema/data, or RLS policies were changed. No commit or push was made.

## Executive summary

Phase 5 already provides a useful local foundation: caregiver-scoped SQLite caches, private local media files, paginated cache preparation, readiness manifests, offline Odd One Out and Everyday Object Sorting sessions, a session/response outbox, and additive database migrations through version 4. A large architecture rewrite is not necessary. Phase 6 should extend the existing store and queue so caregiver and Memory Deck changes use the same local-first path as activities.

The biggest functional gaps are that caregiver profile and Memory Deck/card mutations still write directly to Supabase; newly recorded/imported card media is not saved into a durable local upload queue; synchronization handles only sessions and responses; Memory Deck viewing does not create an activity session or save an elderly response; and unfinished game state is not restored after process restart. The caregiver report screen also reads cloud reporting data only. Cached activity history is available to the activity-history screen, but that screen's direct cloud request is capped at 100 rows.

**Game 3 (Everyday Object Sorting):** the bundled data has six items. `_placements` is an in-memory map keyed by item ID. The “Finish Sorting” button is disabled until `_placements.length == items.length`, so all six items must be categorized. The button is at the bottom of a scrollable page, after all six items and both category buttons, with no visible “X of 6” progress or explanation while disabled. This explains why a person who has categorized only some items cannot finish. Once all six are placed, `_finishSorting` saves one response per item and completes the session. The selections are not persisted before Finish, so an interrupted/in-progress sorting session cannot be resumed after restart.

**APK size:** the supplied debug APK is 225,322,837 bytes (214.89 MiB). A default universal Flutter release APK measured 58,648,361 bytes (55.91 MiB); the ARM64 split measured 20,472,511 bytes (19.53 MiB). This is a 74.0% reduction for universal release and 90.9% for the ARM64 APK, with no feature removal. The debug APK contains all three architecture engines, the debug Dart kernel/runtime payload, and 53,442,376 bytes of empty ZIP alignment records. Release APKs contain neither the debug kernel payload nor those empty records. Use release builds for distribution and split APKs for direct device-specific installation; use an AAB for Google Play delivery.

No production Supabase queries or installed-device SQLite inspection were performed. Flutter tests were not run in this audit; the cited Phase 5 test totals below are from the existing Phase 5 report, not a new test run.

## 1. Existing architecture overview

- `android_app/lib/main.dart` owns authentication gating, caregiver and elderly modes, selected-profile state, profile management, sign-out, and screen navigation. The elderly flow requires a caregiver-owned profile to be selected.
- Supabase Auth identifies the caregiver. The database and Storage remain the cloud source of truth, with RLS as the authorization boundary.
- `OfflineStore` is a singleton around `sqflite`, opening `getDatabasesPath()/kincare_offline.db`. `OfflineCachePreparation` downloads caregiver-visible records and media into SQLite and application-private storage.
- Cognitive game content is bundled in `android_app/assets/cognitive_games.json` (6,495 bytes). The cognitive game screen loads that file locally, then saves sessions and responses to SQLite before sync.
- `OfflineSyncService` checks network, internet, and authenticated Supabase reachability and synchronizes the existing activity outbox. `OfflineSyncStatus` displays the queue state and retry action.
- Memory Deck metadata/cards and downloaded media have a local read path. Caregiver deck/card authoring and media uploads remain direct Supabase operations.
- Reporting is split: `activity_history_screen.dart` combines cloud rows, cached historical rows, and locally created activity rows; `engagement_reporting.dart` loads cloud reporting rows and `caregiver_report_screen.dart` has no local-history fallback.

This design already matches the desired direction: keep one Supabase schema, use Android SQLite/private files for local work, and retain client-specific storage. Phase 6 can build on it.

## 2. SQLite schema and migration history

The current database is **version 4** and creates 13 tables:

| Tables | Purpose |
|---|---|
| `profiles`, `decks`, `cards` | Caregiver-scoped cached profile, deck, and card payloads. |
| `devices` | Caregiver-scoped enrolled-device mapping and revocation state. |
| `media_files` | Caregiver/asset mapping to private local media paths. |
| `sessions`, `responses` | Local activity history. |
| `sync_outbox`, `sync_meta` | Pending activity records, retry state, and last sync time. |
| `caregiver_cache` | Cached caregiver payload used on offline startup. |
| `cached_activity_sessions`, `cached_activity_responses` | Cached cloud activity history. |
| `cache_manifest` | Readiness/failure state for cached content. |

`PRAGMA foreign_keys=ON` is set on open. Fresh schema and migrations enforce `responses.session_id → sessions.id` (`ON DELETE RESTRICT`) and the owner-scoped `cards(caregiver_id, deck_id) → decks(caregiver_id, id)` (`ON DELETE CASCADE`). Versions 1→2 create cache/history tables; 2→3 rebuild `responses` after checking for orphans; 3→4 rebuild `cards` after checking for orphans. Existing row copies are performed during the upgrade transaction.

There is not yet a declared local FK for deck-to-profile, session-to-profile/device/deck, or media-to-card/asset. Caregiver ownership is also carried in SQLite columns and enforced by repository filters and sync-time checks. Cached history intentionally needs to remain readable when a profile snapshot is refreshed or unavailable. Do not add constraints that would delete or make historical rows inaccessible; any future FK migration needs orphan preflight and preservation tests.

The Phase 5 report records passing isolated tests for fresh schema, v1 upgrade, activity/outbox preservation, FK behavior, rollback, owner-scoped cache, 1,207-row pagination, media verification/reuse, and sync queue transitions. The Phase 5 report says 25 tests passed. That result was not rerun for this audit.

## 3. Current offline capabilities

| Capability | Status | Evidence / limits |
|---|---|---|
| Previously authenticated caregiver startup | **Partially implemented / requires device verification** | `AuthGate` uses the persisted Supabase session. `CaregiverScreen._loadData` falls back to cached caregiver details and profiles after a cloud-load failure. Expired-session startup with no internet has not been verified and can depend on Auth refresh behavior. Passwords are not stored in SQLite. |
| Elderly profile selection | **Partially implemented** | Profile selection uses locally loaded profiles after cache preparation. Current caregiver create/edit/delete handlers write directly to Supabase; no local mutation queue exists. |
| Offline game content | **Already implemented** | Bundled JSON is loaded through `rootBundle`; no network is needed for predefined questions. |
| Offline game session/response persistence | **Partially implemented** | Both cognitive games create local sessions and queue responses. A previously enrolled device and locally cached authorized profile are required. Odd One Out saves each round; sorting only saves on Finish. No unfinished-game restoration is implemented. |
| Memory Deck offline viewing | **Partially implemented** | Caregiver-visible decks/cards/media are prepared locally and the elderly viewer falls back to SQLite/local files. A deck is marked ready only after required media paths verify. First-time content still requires an online preparation/download. |
| Offline Memory Deck authoring | **Missing** | Deck/card CRUD, photo/audio upload, and `media_assets` creation call Supabase directly. There is no durable local mutation queue for those operations. |
| Elderly Memory Deck response/activity history | **Missing in the inspected Flutter flow** | `ElderlyMemoryScreen` displays questions, story, and caregiver-recorded audio, but does not call `createSession`, `saveResponses`, or `finishSession`, and has no elderly response recorder. Therefore opening/advancing cards does not create the activity records expected by the reporting flow. |
| Offline activity history | **Partially implemented** | Activity history merges cached sessions/responses and local sessions/responses. Its direct cloud query uses `.limit(100)`; cache preparation itself paginates. |
| Offline dashboard/report/PDF | **Missing / partial** | `loadCaregiverReportingData` paginates Supabase sessions but `CaregiverReportScreen` has no SQLite fallback. PDF generation is local after records load, but data loading still requires Supabase. |
| Media download/reuse | **Already implemented for downloaded media** | Downloads use temporary files, non-empty/optional size checks, atomic rename, owner-scoped paths, and `cacheMediaIfNeeded` reuse/coalescing. These are download-cache paths, not a pending-upload implementation. |
| Connectivity and activity sync | **Partially implemented** | Network, internet probe, Supabase response, queue, failed, and retry states exist. Only `session` and `response` outbox entity types are supported. |

## 4. Operations that still depend on Supabase

The following ordinary caregiver operations currently require Supabase:

- caregiver display-name update;
- elderly profile create, edit, and delete;
- Memory Deck create, edit, and delete;
- card create, edit, and delete;
- uploading a photo or caregiver-recorded question/answer audio, then creating `media_assets` metadata;
- fresh account login, first-time profile/device enrollment, and cache preparation;
- cloud report loading and PDF data coverage beyond locally cached activity.

Offline game play is available after the caregiver/profile/device prerequisites have been cached/enrolled. Activity sync requires a valid authenticated caregiver session, accessible profile, non-revoked enrolled device, and reachable Supabase.

## 5. Game 3 sorting interaction — exact condition

In `CognitiveGamesScreen._buildSorting`, each selected object is assigned to `_placements[item['id']]` when a category button is tapped. The map lives only in the screen `State`; it is not written to SQLite at each placement. The Finish button's `onPressed` is set to `null` unless `_placements.length == items.length && !_busy`. `_finishSorting` repeats the same count guard, then creates one response per bundled item, writes them through `_saveResponses`, and completes the session.

The current JSON has six sorting objects (`apple`, `banana`, `mango`, `carrot`, `potato`, `cabbage`) and two categories. Consequently:

1. Categorizing fewer than six unique item IDs leaves Finish disabled by design.
2. There is no remaining-items/progress message to explain the disabled state.
3. Finish is below the full scrollable object list and category controls, so it may not be visible until the user scrolls.
4. If the screen/process is left before Finish, no sorting responses have been saved and the six local placements are lost; the started session remains in progress.

The bundled IDs are unique, and the completion handler itself uses the correct map entries after the count gate. I found no evidence that the handler is unreachable once all six items are categorized. Proposed fix: make the requirement obvious with an always-visible `X of 6 categorized` indicator, highlight unplaced items, provide a visible scroll-to/anchored Finish action, and checkpoint each placement locally by session/item ID. Reopening an in-progress session should restore the checkpoint. Preserve the current append-only cloud response contract by writing final responses once on completion, or use versioned local drafts until completion.

## 6. Data ownership and security assessment

- Authenticated caregiver ID is used as the local owner key. Cache tables and media lookups filter by that owner; pending outbox entries retain their original `caregiver_id`.
- Cache preparation is run with the authenticated Supabase client and relies on existing RLS-visible rows. It verifies the caregiver identity again before using results. No service-role credential is present in Flutter code.
- Activity sync validates the owner, profile visibility, enrolled device/revocation state, and activity type. Existing IDs are checked remotely to prevent duplicate inserts or cross-profile/device ID collisions.
- Sign-out stops active sync and `clearSyncedCache` removes synced cache/activity while protecting sessions with pending responses. Pending records remain scoped to their original caregiver. The existing Sign-out implementation should be preserved and regression-tested.
- Local cache access still depends on Supabase Auth restoring a caregiver session. If the token has expired while the device is offline, access may not be possible until the session is safely revalidated. Do not store passwords or silently allow a different caregiver to open another caregiver's cache.
- A local account switch must never rewrite ownership on queued items. Clear only that caregiver's synced cache after confirmed sign-out; keep pending records and their media files until acknowledged or explicitly discarded through a reviewed user flow.

## 7. Local media assessment

Downloaded Memory Deck files are kept in application-private storage under caregiver/asset-specific paths, and `media_files` records the path. The downloader writes a `.part-*` file, flushes/verifies it, then renames into place. This handles interrupted downloads without treating partial files as ready. Existing valid media is reused on retry.

The current authoring flow is different: `ImagePicker` and `record` produce local source files, but `_DeckForm`/`CardEditorScreen._save` uploads them to Supabase Storage immediately and then inserts `media_assets` and card metadata. Those files are not registered as durable local pending-upload records. A failed upload can leave the editor in an error state, but a full offline restart/retry path is not implemented.

Phase 6 should keep the original photo/audio bytes locally, create stable asset IDs and owner-scoped metadata, and queue them for upload. Upload ordering must be: media bytes → `media_assets` metadata → deck/card references. Never remove the local copy until the cloud acknowledgement and dependent metadata writes succeed. Use the existing private bucket/RLS policies and signed URLs; do not weaken Storage authorization. Store MIME type, byte count, stable storage path, upload state, retry count, and optional content hash locally. Treat picker and recorder permissions/errors as user-visible states.

## 8. Synchronization audit and weaknesses

**Already implemented:** activity session/response writes are transactionally paired with outbox entries; retry state and manual retry exist; remote IDs are checked for idempotency; session/profile/device ownership is revalidated; account-generation checks prevent stale work from being acknowledged after owner changes; and sign-out preserves pending activity.

**Missing for local-first CRUD:** `OfflineSyncService` only handles `session` and `response`. It has no create/update/delete handlers for profiles, decks, or cards, and no media-upload job. There is no durable conflict record or deletion tombstone. Current cloud cache refresh methods replace profile rows and card rows for an owner/deck, which would overwrite dirty local edits if local changes were placed in those same tables without adding dirty-state protection.

**Risks to handle:** app termination during upload; partial media/metadata/card commits; RLS rejection after a caregiver's access changes; simultaneous edits from another device; account switching while a request is in flight; storage quota/full disk; retry after partial success; and deletion while sessions/cards still reference the profile/deck. Keep every failed operation and its source file for review/retry. A remote API error is not proof that a write did not commit; use stable IDs and read-before-retry checks.

## 9. Recommended target architecture

Extend the current `OfflineStore` and `OfflineSyncService`; do not replace SQLite or Supabase.

1. Treat owner-scoped local repositories as the source for screens. UI mutations commit locally first, update `cache_manifest`/local sync state, and return a clear “saved on this device” state.
2. Reuse stable UUID IDs (`uuid` is already a dependency). Keep local sync metadata separate from Supabase payload fields; send only current contract columns.
3. Extend the outbox with explicit operation kinds (create/update/delete) for profile, deck, card, and media entities. Existing session/response queue behavior must remain backward-compatible.
4. Queue local media and preserve its private file. Sync in dependency order (media bytes, media metadata, deck, card), then mark only the acknowledged operation synced.
5. Keep deletes as local tombstones until the existing Supabase delete succeeds. Retain local content on RLS/FK failure and report that it needs attention; do not introduce cloud tombstone columns without schema approval.
6. Store an edit base snapshot locally and detect when the cloud version differs. Do not silently overwrite either copy; show a simple conflict choice and retain both until resolved.
7. Checkpoint unfinished game state locally. For sorting, save category draft state per session/item and restore it after restart; only publish append-only final responses when the game completes.
8. Add a Memory Deck activity session and response capture flow to the elderly viewer, with text fallback if recording is denied. Locally save the audio file, response metadata, and session before synchronization.
9. Build caregiver history/reporting from a merge of cloud, cached history, and pending local activity. Deduplicate on stable session/response IDs and label synced vs pending coverage.
10. Keep all writes scoped to `caregiver_id`; keep Supabase RLS and private Storage as the cloud security boundary. Recheck the current user before each remote write and before local acknowledgement.

## 10. APK size investigation and measurements

### Measured APK sizes

All APK sizes below were built from the current Flutter project using its existing Supabase URL and publishable-key build defines. The release variants use the existing `build.gradle.kts` release signing configuration, which currently signs with the **debug key**; these are size measurements, not distributable production-signed artifacts.

| Build | APK bytes | File size (MiB) | APK Analyzer estimated download size |
|---|---:|---:|---:|
| Existing debug APK (universal) | 225,322,837 | 214.89 | Not measured; debug is not a distribution target |
| Release APK (universal, default Flutter release) | 58,648,361 | 55.91 | 26,367,511 bytes (25.14 MiB) |
| Release APK (ARM64, split-per-ABI) | 20,472,511 | 19.53 | 9,399,290 bytes (8.96 MiB) |
| Release APK (ARMv7, split-per-ABI) | 18,055,707 | 17.22 | 8,982,042 bytes (8.57 MiB) |
| Release APK (x86_64, split-per-ABI) | 21,963,971 | 20.94 | 9,579,697 bytes (9.14 MiB) |

The Flutter `--analyze-size` ARM64 release report produced a 20,709,895-byte target-platform APK (19.75 MiB); its exact artifact is not the `--split-per-abi` output in the table. It reported approximately 19 MB of ARM64 native libraries, 132 KB `flutter_assets`, 479 KB DEX, and 7 MB of decompressed Dart AOT symbols. Within the symbol accounting, it attributed 3 MB to `package:flutter`, 373 KB to KinCare, and 153 KB to `package:pdf` (symbol-accounting sizes, not additive compressed APK sizes).

### What makes the debug APK large

Android `apkanalyzer apk file-size` confirms 225,322,837 bytes for the existing debug APK. APK entry inspection found:

- Three debug Flutter engines: `libflutter.so` is 38,846,424 bytes (ARM64), 33,159,780 bytes (ARMv7), and 40,107,168 bytes (x86_64), before considering other libraries.
- A debug Dart kernel payload: `assets/flutter_assets/kernel_blob.bin` is 82,253,904 bytes uncompressed (27,871,095 bytes compressed). Release uses AOT `libapp.so` instead; the debug kernel and VM/isolate snapshot content are absent from release APKs.
- `libVkLayer_khronos_validation.so` is 15,240,080 bytes in the ARM64 debug APK, plus `libsqlite3.so` files of roughly 1.7 MB for each ABI. The release APKs do not contain these files. The exact dependency/build-task origin of these debug-only libraries was not established, so they should not be removed based on this audit alone.
- The debug archive contains 842 empty-name/zero-data ZIP local padding records totaling 53,442,376 bytes. The release universal and ARM64 APKs contain zero such records. This is packaging padding in the debug artifact, not bundled KinCare photos/audio. `zipalign -c -P 16 -v 4` verifies both debug and release APKs. The padding was observed directly; no single Gradle DSL setting was identified as its generator.
- Debug has a 13.66 MB uncompressed multidex payload and a 1.65 MB Material Icons font. In release, the Flutter build tree-shakes `MaterialIcons-Regular.otf` from 1,645,184 bytes to 6,528 bytes (99.6%).

The release universal APK contains native binaries for all three ABIs; the split ARM64 APK includes only ARM64 native binaries. The measured savings are **74.0%** from debug to universal release and **90.9%** from debug to ARM64 split. The ARM64 split is **65.1% smaller** than the universal release APK. These are measured size reductions, not forecasts.

### Asset and dependency findings

- `pubspec.yaml` declares one Flutter asset: `assets/cognitive_games.json` (6,495 bytes). No bundled Memory Deck photos or audio recordings were found. Deck media is downloaded to app-private storage, so it should not be removed to reduce APK size; it is necessary for offline decks after caching.
- Release size is dominated by the Flutter engine and AOT application library, not by the small game JSON or bundled game media. There are no large image/audio assets or obvious duplicate KinCare assets to remove.
- Direct size-relevant dependencies include `flutter_tts`, `record`, `audioplayers`, `image_picker`, `pdf`, `printing`, and the Supabase/SQLite/connectivity plugins. Audio, voice, image, offline database, and PDF/reporting are required functionality. Flutter TTS uses the device's Android TTS engine; the app does not bundle a Hindi voice model. Flutter's symbol report accounts for 153 KB decompressed Dart symbols under `package:pdf`, not a major share of the APK.
- `sqflite_common_ffi` is a development dependency. Debug includes `libsqlite3.so`, while the measured release APKs do not. Do not remove or alter the test dependency until the Android packaging path is specifically traced.
- Release `build.gradle.kts` does not enable `minifyEnabled` or `shrinkResources`, and no `abiFilters` are configured. The release APK is already substantially smaller due to Flutter release AOT/tree shaking, but its universal form still includes three ABIs.
- No safe production dependency or asset deletion was identified. No image/audio recompression is currently applicable to bundled assets.

### Safest optimization plan

1. **Do not distribute the debug APK.** Build a release artifact. This alone measured a 74.0% size reduction for the universal APK while retaining features.
2. **For direct APK distribution, use `--split-per-abi`.** Select ARM64 for current 64-bit ARM devices, while retaining ARMv7/x86_64 files only when those architectures must be supported. Use the exact matching APK when sideloading.
3. **For Google Play, prefer AAB.** Play generates configuration-specific APKs so users download the ABI/resources needed for their device. The AAB file itself is a publishing container and is not equivalent to an installed per-device APK size; no AAB/Play download was measured here.
4. **Evaluate R8/resource shrinking only after a release smoke test and a before/after measurement.** The measured DEX/resources are much smaller than Flutter native libraries, so further savings are likely limited; reflection and plugin registrations need keep-rule testing. No shrinker change was made.
5. **Keep all audio, TTS, recording, image selection, SQLite, and offline media features.** No speculative dependency removal or remote-only media change is recommended.
6. **Set up a production release signing key only as a separately authorized release task.** The current measured release outputs are debug-signed.

### Reproduction commands

Run in a Windows `cmd.exe` batch context from `android_app`, after loading the existing local build configuration. Keep actual values in `local_build_config.bat`; do not paste the publishable key into source or this report.

```bat
cd /d D:\kincare-round3\android_app
call ..\local_build_config.bat

rem Flutter ARM64 release size analysis
flutter build apk --release --analyze-size --target-platform android-arm64 --dart-define=SUPABASE_URL=%SUPABASE_URL% --dart-define=SUPABASE_PUBLISHABLE_KEY=%SUPABASE_PUBLISHABLE_KEY%

rem Universal release APK
flutter build apk --release --dart-define=SUPABASE_URL=%SUPABASE_URL% --dart-define=SUPABASE_PUBLISHABLE_KEY=%SUPABASE_PUBLISHABLE_KEY%

rem Per-ABI release APKs
flutter build apk --release --split-per-abi --dart-define=SUPABASE_URL=%SUPABASE_URL% --dart-define=SUPABASE_PUBLISHABLE_KEY=%SUPABASE_PUBLISHABLE_KEY%

rem Google Play upload bundle (not measured in this audit)
flutter build appbundle --release --dart-define=SUPABASE_URL=%SUPABASE_URL% --dart-define=SUPABASE_PUBLISHABLE_KEY=%SUPABASE_PUBLISHABLE_KEY%
```

APK Analyzer commands used for exact archive/download estimates:

```bat
"%LOCALAPPDATA%\Android\Sdk\cmdline-tools\latest\bin\apkanalyzer.bat" apk file-size build\app\outputs\flutter-apk\app-debug.apk
"%LOCALAPPDATA%\Android\Sdk\cmdline-tools\latest\bin\apkanalyzer.bat" apk file-size build\app\outputs\flutter-apk\app-release.apk
"%LOCALAPPDATA%\Android\Sdk\cmdline-tools\latest\bin\apkanalyzer.bat" apk download-size build\app\outputs\flutter-apk\app-release.apk
```

Flutter's APK analysis JSON was emitted at `C:\Users\Asus\.flutter-devtools\apk-code-size-analysis_01.json`. Official guidance: [Flutter Android build/release](https://docs.flutter.dev/deployment/android) and [Android app size reduction and App Bundles](https://developer.android.com/topic/performance/reduce-apk-size).

## 11. Files likely to change in Phase 6

These are candidates for a later implementation, not files changed in this audit:

| File | Planned responsibility |
|---|---|
| `android_app/lib/offline_store.dart` | Additive v5 migration; durable local CRUD/checkpoints; operation/tombstone/media metadata; owner-scoped repositories; preserve existing cache/outbox rows. |
| `android_app/lib/offline_sync.dart` | Add ordered idempotent sync handlers for local profile/deck/card/media operations; conflict/retry handling; retain existing activity logic and account-generation checks. |
| `android_app/lib/offline_cache_preparation.dart` | Merge cloud refresh without overwriting dirty local rows; preserve cache-ready and partial media states. |
| `android_app/lib/main.dart` | Route caregiver profile changes through local-first repository; restore/reselect locally cached profiles; show local/synced state. |
| `android_app/lib/memory_decks_screen.dart` | Local-first deck/card authoring, durable photo/audio drafts, delete tombstones, retry and cache state. |
| `android_app/lib/elderly_memory_screen.dart` | Add local Memory Deck activity/session/response capture and offline response audio/text handling; keep hidden story behavior. |
| `android_app/lib/cognitive_games_screen.dart` | Save/restore in-progress session state and per-item sorting drafts; show clear completion progress and reachable Finish action. |
| `android_app/lib/activity_history_screen.dart` | Paginate the cloud list and merge/deduplicate cloud, cached, and pending records. |
| `android_app/lib/engagement_reporting.dart`, `caregiver_report_screen.dart`, caregiver dashboard in `main.dart` | Derive reports from local+cloud rows and label coverage/sync state accurately. |
| `android_app/test/` | Add repository, migration, restart, retry, and fake-sync coverage without production backend access. |
| `android_app/android/app/build.gradle.kts` | Only if a measured R8/resource-shrink experiment or production signing setup is separately approved. |

No PWA file, Supabase migration, or RLS policy needs to change for the proposed local-only database/outbox work. Any payload-semantic or shared API contract change must be documented in `docs/API_CONTRACTS.md` before implementing both clients.

## 12. Proposed non-destructive database migration

Use **version 5** only when local-first operations are implemented. Preserve v4 and add fields/tables in an upgrade transaction; never delete/recreate `kincare_offline.db`.

1. Keep all current PKs, caregiver IDs, media paths, activity records, and outbox IDs. Run preflight queries for orphan/duplicate relationships before any table rebuild.
2. Add local-only mutation status and deletion tombstone data for profiles/decks/cards. Preserve a local base snapshot or a local conflict table so remote cache refresh can distinguish clean cache from pending local edits.
3. Add an explicit operation field for existing outbox rows with a backward-compatible default so existing `session`/`response` records still sync identically. Add indexes for owner/state/next-retry and entity dependencies.
4. Extend local media metadata with pending upload state, media type, storage path, content size/hash, retry count/error, and stable owner-scoped ID. Keep original files through upload/metadata/card acknowledgement.
5. Do not add cloud columns. Translate local payloads into only the existing `CAREGIVERS`, `ELDERLY_PROFILES`, `MEMORY_DECKS`, `MEMORY_CARDS`, `MEDIA_ASSETS`, Storage, and activity contract fields already allowed by the current schema/RLS.
6. Keep tombstones until the existing RLS-authorized remote delete succeeds. If dependent rows or RLS prevent it, retain local data and show the error.
7. Add migration fixtures from both v1 and v4 containing synced and pending sessions/responses, cached content/media references, and per-caregiver rows. Verify rollback on malformed/orphan data and that no pending rows/files disappear.

Any need for a new server timestamp, soft-delete column, bucket, policy, or RPC is a contract/schema proposal and must stop for backend-owner approval; it is not assumed here.

## 13. Recommended implementation phases

1. **Repository boundary and local state model:** add testable owner-scoped local repository APIs and v5 migration; keep all old rows readable. Prevent cache refresh from replacing dirty local rows.
2. **Profile CRUD:** create/update/delete offline with stable IDs and tombstones; show “saved on device” separately from “synced”; sync and resolve ownership errors.
3. **Memory Deck/card drafts and media:** persist edits and picked/recorded files privately; complete deck/card creation locally; implement ordered media upload and retries.
4. **Unfinished activity restoration:** checkpoint sorting placements and game stage; restore local sessions after app restart. Add Memory Deck session/response capture and offline recording/text fallback.
5. **Bidirectional sync and conflict UX:** profile/deck/card/media operations, idempotency, conflicts, account switching, sign-out, restart and partial failure handling. Preserve pending records.
6. **History/reporting and polish:** merge/dedupe all data sources; distinguish local pending from server-synced totals; storage status, progress, retry and deletion messaging.
7. **Release/distribution verification:** run automated suites, device offline sequence, signed release build, ABI/App Bundle size check. Keep debug build for development.

## 14. Automated testing strategy

Reuse `sqflite_common_ffi`, existing widget tests, and fake/injected services. Do not add another test framework or point tests at production Supabase.

- **Migration/SQLite:** create fresh v4 and legacy v1 databases in temporary directories; upgrade to v5; preserve IDs, payloads, timestamps, pending state, and media paths; verify constraints, rollback, and no owner leakage.
- **Transactions:** force failure between local entity write and outbox write; assert neither is partially committed. Verify delete tombstones and response/session integrity.
- **Local CRUD/restart:** create/edit/delete caregiver profile, deck, card and media metadata; close/reopen the database; assert local screen repositories restore the same data and drafts.
- **Cache safety:** refresh cloud snapshots while dirty rows exist; ensure dirty payloads survive; ensure ready/partial state reflects every required photo/audio file.
- **Media:** use synthetic nonempty bytes in a temp folder; verify interrupted partial file cleanup, no duplicate download/upload, hash/size checks, media-first ordering, failed upload retry, and source file retention.
- **Pagination/history:** more than 500 sessions/responses, stable ordering, duplicate cloud/cache/local IDs, profile scoping, and offline report coverage. Cover the Activity History screen's 100-row online limit.
- **Sync:** fake Supabase and Storage endpoints; test create/update/delete idempotency, duplicate retry after ambiguous success, dependency ordering, backoff/forced retry, process interruption, partial success, RLS denial, and per-caregiver isolation.
- **Game 3:** widget test with six bundled items; verify Finish disabled at 5/6, enabled at 6/6, progress text/scroll behavior, corrected placements, local checkpoint, and restoration after reconstructing the screen.
- **Memory Deck:** fake audio files and local player boundary; test offline deck/card playback, question/story reveal, record denied fallback, saved response/session after restart.
- **Auth/sign-out:** no passwords in DB; restore last valid caregiver offline; expired token/offline behavior; sign-out online/offline; account switch during sync; pending activity/media remains owned by original caregiver.
- **UI/status:** local-only vs synced labels, progress, storage-full state, retry action, and conflict/delete feedback.

Tests must use synthetic caregivers/profiles and fake Supabase services; no real tokens, caregiver accounts, Storage writes, or database cleanup against production.

## 15. Physical-device acceptance tests

Automated SQLite fakes do not prove Android filesystem, token refresh, audio, or network behavior. Test with a dedicated Android device and synthetic account:

1. Authenticate online; select two profiles; prepare multiple decks with photos and question/answer audio. Confirm cached media opens from app-private storage with airplane mode on.
2. Create, edit and delete a profile/deck/card offline. Force-stop and relaunch. Verify drafts remain and status says saved locally/pending.
3. Record/import photo and audio offline; deny/regrant microphone/storage permissions; check usable fallbacks and that no local source file disappears after failure.
4. Start each cognitive game offline. For Sorting, categorize 1–5 items and confirm remaining progress is clear; force-stop mid-game; reopen and continue; complete and inspect local session/response IDs.
5. Open a Memory Deck offline, answer with audio and text fallback, advance cards, restart, and verify session/response/history recovery.
6. Reconnect under normal Wi-Fi, Wi-Fi without internet, mobile data, and a Supabase outage. Verify distinct states and only one cloud record per stable local ID.
7. Kill the app during a media upload and during session sync; restart and retry. Check no duplicate asset, deck, card, session, or response and no lost local file.
8. Switch caregiver accounts while queued work exists. Verify account B cannot display or sync account A's pending records; sign out with pending work and confirm it remains for A.
9. Revoke a device/profile access remotely and retry; verify RLS denial is shown while local data remains preserved.
10. Fill device storage or deny app storage access; confirm cache does not say ready for a missing file and existing content is retained.
11. Generate the caregiver report offline with pending records; verify coverage labels and totals are factual and include local activity only when explicitly labeled.
12. After successful sync, inspect caregiver activity history and the PWA for expected cross-client records. This is a live-backend test and must be recorded separately from local-only tests.

No physical-device, production database, or live Supabase test was performed in this audit.

## 16. Risks and backward-compatibility safeguards

- **Cached refresh overwrites drafts:** add dirty-state handling before routing local CRUD into the existing cache tables; preserve clean cache behavior and pending outbox rows.
- **Delete/FK failures:** retain tombstones and dependent data until the server acknowledges; do not cascade-delete pending sessions/responses or media.
- **Partial sync:** use stable IDs and idempotent read-before-retry; never infer failure solely from a timeout after a remote request.
- **Caregiver isolation:** include caregiver ID in local queries, filenames, manifests, mutation rows, and sync selection. Recheck Auth owner before each remote write/acknowledgement.
- **Offline token expiry/revocation:** clearly distinguish locally cached identity from currently authorized cloud access. Never store passwords or use a service key; require safe online revalidation before cloud operations.
- **Conflicting edits:** preserve the base snapshot and both versions; avoid silent last-write-wins until the caregiver resolves a visible conflict.
- **Media storage:** keep local copies until all dependent server metadata is acknowledged. Plan for user-cleared app storage and quota exhaustion; mark missing content unavailable rather than ready.
- **Append-only history:** do not mutate already-published activity responses to represent draft edits. Keep drafts local until completion; retain existing response IDs and sync semantics.
- **Legacy compatibility:** migration tests must start from versions 1 and 4 and preserve all pending IDs/state. Do not clear, reset, or recreate the existing database during rollout.
- **Release size/signing:** do not ship debug APKs; measured release outputs remain debug-signed and must not be treated as production-ready. No APK size optimization or build configuration change was made.

## Audit verification log

- Inspected the master specification, API/offline-sync contracts, Phase 5 report, Flutter cache/store/sync/auth/game/memory/history/report sources, tests, Android Gradle configuration, and `pubspec.yaml`.
- Built ARM64 release analysis, universal release APK, and ABI-split release APKs. Flutter reported successful builds; APK Analyzer measured the exact file and estimated download sizes in Section 10.
- `zipalign -c -P 16 -v 4` verification succeeded for debug and universal release APKs.
- Existing debug APK remained at 225,322,837 bytes with its original 2026-11-24 17:07:31 timestamp. Its SHA-256 after measurement is `66431EACCD0932F37B12A66C2AFD7B320851C4079566B243A04ED08D458D713A`.
- `flutter test`, coverage, and `flutter analyze` were **not run** as this audit is measurement and planning only. The Phase 5 report's tests were not independently revalidated here.
- No live Supabase data, production DB, RLS, or on-device SQLite was accessed.
