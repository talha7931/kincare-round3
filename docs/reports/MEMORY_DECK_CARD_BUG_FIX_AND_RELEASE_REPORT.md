# Memory Deck Card Persistence Fix and Release Report

**Date:** 2026-11-25  
**Branch:** `feature/phase5`  
**Package:** `com.kincare.kincare_android`

## Result

The card visibility and retry defects were reproduced with isolated SQLite and mocked Supabase tests, then fixed. The universal release APK was built from the fixed source and verified. No Supabase schema, RLS, authentication configuration, or production data was changed.

## Root causes

1. `OfflineStore.cacheDeck()` refreshed an existing deck using SQLite `INSERT OR REPLACE`. SQLite implements `REPLACE` by deleting the old parent row first. The cards table has a foreign key to decks with `ON DELETE CASCADE`, so a deck refresh could silently delete its locally saved cards. This happened even when the card insert transaction and outbox write had succeeded.
2. A stale cloud card response could arrive after sync completed. Cache reconciliation treated the card as synced and absent from the older response, then removed it. Pressing Sync could not help because the outbox item had already been marked complete.
3. If a card create did fail, the outbox retry marked it `failed`; the next sync treated a missing cloud row in that state as a conflict instead of retrying the create.
4. The elderly Memory Deck screen used the cloud response directly after caching it, so a successful empty cloud response hid cards that were still present locally.

The first regression test failed before the fix with the local card list empty after the refresh (`Expected length 1; actual length 0`). The mocked sync test also exposed that a failed create was moved to conflict and not inserted on retry.

## Changes made

- `OfflineStore.cacheDeck()` now updates an existing deck row in place, avoiding the foreign-key cascade. It accepts the time a remote card snapshot began and only removes absent synced cards that were already older than that snapshot. A card synced after a fetch began therefore survives that stale response; a later authoritative response can still reconcile deletions.
- Successful card sync refreshes the card’s local cache timestamp for that protection.
- `saveCardLocal()` rejects an empty card ID or a card payload whose `deck_id` differs from the target deck.
- Caregiver deck/card refreshes use the merged local card list and load cached cards before awaiting the remote refresh. Card counts continue to derive from the local list.
- The elderly Memory Deck screen now displays the merged local card list after cloud refresh, preserving unsynchronized cards.
- Failed local creates with no cloud baseline are eligible for retry. Failed updates with a baseline retain the existing conflict handling.
- Local card reads include sync state. Failed cards show a clear message that the card remains saved locally and can be retried with **Sync Now**. The detailed sync error remains in the outbox rather than being copied into card payloads.
- Added isolated tests using the existing SQLite FFI setup and a mocked Supabase HTTP client. `http` was added as a test-only dependency for this mock; production dependencies and runtime behavior are unchanged.

### Files changed for this task

- `android_app/lib/offline_store.dart`
- `android_app/lib/offline_sync.dart`
- `android_app/lib/memory_decks_screen.dart`
- `android_app/lib/elderly_memory_screen.dart`
- `android_app/lib/offline_cache_preparation.dart`
- `android_app/test/offline_store_behavior_test.dart`
- `android_app/test/memory_card_sync_test.dart`
- `android_app/pubspec.yaml`
- `android_app/pubspec.lock`
- `docs/reports/MEMORY_DECK_CARD_BUG_FIX_AND_RELEASE_REPORT.md`

The working tree contained unrelated Phase 5/6 changes before this task; those were preserved.

## Regression coverage and results

The SQLite tests cover local card visibility and content, card/deck identity validation, sync queue uniqueness, parent/media/deck/card ordering, restart persistence, cache refresh while pending, stale refresh after sync, later authoritative deletion, and failed-card preservation/retry.

The mocked Supabase tests cover failed create followed by retry, surfaced failed state, recovery to synced state, a lost insert response confirmed by stable ID, and repeated sync without another insert. The mock is isolated; it does not contact the production Supabase project.

| Check | Result |
|---|---|
| Targeted tests: `flutter test test/offline_store_behavior_test.dart test/memory_card_sync_test.dart` | **PASS**, 14 tests |
| Full suite: `flutter test` | **PASS**, 42 tests |
| Flutter analysis: `flutter analyze --no-pub` | **No errors; 27 informational lint/deprecation notices; exit code 1** |
| Debug build: `flutter build apk --debug --no-pub` | **PASS** |
| Universal release build | **PASS**, command below |
| `git diff --check` | **PASS**, with only existing LF/CRLF normalization warnings |

The analyzer notices are informational style/deprecation findings, including findings in existing files; the analyzer reported no compile errors.

## Final submission APK

Built from `D:\kincare-round3\android_app` with the required local Dart configuration:

```text
flutter build apk --release --target-platform android-arm,android-arm64,android-x64 --dart-define-from-file=dart-defines.json
```

- **Path:** `D:\kincare-round3\android_app\build\app\outputs\flutter-apk\app-release.apk`
- **Size:** 59,271,221 bytes (56.5 MiB; approximately 59.3 MB decimal)
- **SHA-256:** `5B5D80D180DA7F969A3941F986A5F66D8D51BF0C735388AA8BCEDBD9718B60BD`
- **Build timestamp:** 2026-11-25 19:31:56 local time
- **ABIs:** `armeabi-v7a`, `arm64-v8a`, `x86_64`
- **Package/version:** `com.kincare.kincare_android`, version `1.0.0` (version code `1`)
- **Release INTERNET permission:** present in merged release manifests and the final APK manifest
- **APK signature verification:** passed with Android `apksigner`
- **Local Dart defines:** `dart-defines.json` was present and passed to the release build. No key values were printed or copied into source.

The artifact is larger than 50 MB. It was not reduced by removing features, offline data support, or media. If Unstop enforces a strict 50 MB upload limit, this APK may be rejected; size optimization would need a separate safe investigation.

## Limitations

- No physical phone was connected for this task, so UI behavior was not tested on the Motorola device.
- Sync verification used a local mock PostgREST endpoint. A live Supabase card insert and caregiver history display were not tested.
- Offline creation/retry was validated through isolated SQLite and mocked sync tests, not through a physical disconnect/reconnect cycle.
- Flutter emitted Gradle warnings about plugin Kotlin Gradle Plugin compatibility (`flutter_tts`, `record_android`) and restricted Java native access; both requested builds nevertheless succeeded.
- No commit or push was made.
