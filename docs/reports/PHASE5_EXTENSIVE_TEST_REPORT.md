# KinCare Phase 5 Extensive Test Report

**Date:** 2026-11-24  
**Branch:** `feature/phase5`  
**Scope:** Android Phase 5 offline storage, cache, authentication boundaries, reachability and synchronization. Testing only; no application code, tests, dependencies, Supabase data or schema were changed during this audit. This report is the only file created.

## Executive summary

**Acceptance decision: INCONCLUSIVE.** The existing Flutter unit/widget suite passes, but it does not exercise SQLite, network failures, Supabase synchronization, or offline app restart. There is no connected Android device and no isolated Supabase test environment available, so the core physical offline journey and cloud idempotency could not be verified.

Static inspection found significant gaps: offline status does not reliably distinguish internet failure from Supabase failure; cache preparation does not include all history (it caps sessions at 500), cached caregiver details are written but not read on startup, and cache completion/progress does not account for media. The existing automated tests do not include Phase 5 storage/sync tests.

## Git state

- Before testing: branch `feature/phase5`; existing Phase 5 source, dependency, documentation, and PWA work was already modified/untracked.
- After testing: same branch and same pre-existing changes, plus this report. No source/test/config/dependency files were modified by the audit. No commit, push, stash, checkout, reset, or cleanup was performed.
- `git diff --check`: no whitespace errors; Git printed line-ending conversion warnings for existing modified files.

## Environment and evidence limits

- Repository: `D:\kincare-round3`; Flutter app: `android_app`.
- `flutter test`: 11 passed.
- `flutter test --coverage`: 11 passed; coverage run produced the coverage artifact under `android_app/coverage/`.
- `flutter analyze`: exit code 1 with 32 `info` diagnostics (curly-brace style and one deprecation); no analyzer `error` diagnostics were printed.
- `adb` is unavailable in the shell; no physical device evidence could be collected.
- No safe isolated SQLite integration harness or live test Supabase project was available. The installed app's private SQLite database and its rows were not inspected. No production data was queried or changed for this audit.

## Implementation facts from code inspection

- SQLite path: `getDatabasesPath()/kincare_offline.db` (`offline_store.dart`, `database` getter).
- Base tables: `profiles`, `decks`, `cards`, `devices`, `media_files`, `sessions`, `responses`, `sync_outbox`, `sync_meta`.
- Version 2 adds `caregiver_cache`, `cached_activity_sessions`, `cached_activity_responses`, `cache_manifest`; `onUpgrade` adds these tables for versions below 2 without deleting existing tables. There are no foreign-key declarations in the shown DDL. Indexes cover outbox owner/state/retry, session owner/profile/time, and response session/index.
- Session creation plus queue insertion, response plus queue insertion, and finalizing a session are SQLite transactions (`createSession`, `saveResponses`, `finishSession`).
- Cache preparation is started after online caregiver/profile load (`main.dart` `_loadData`, `_prepareOfflineData`) and on network-availability events. It downloads all returned decks/cards and associated asset rows, writes media under app-private support storage, and records manifest states. Game content is bundled at `assets/cognitive_games.json`.
- Historical cache fetch is limited to 500 sessions (`offline_cache_preparation.dart` `prepare`); there is no pagination. Cache progress counts profiles/decks, not each card/media transfer. Card rows are saved before media completion. Manifest marks a deck `partial` when an asset is missing/failed, but the elderly deck UI does not consult this manifest to gate availability or clearly mark individual unavailable assets.
- `caregiver_cache` is populated, but `_loadData` offline fallback reads cached elderly profiles only. It does not restore caregiver display name from `caregiver_cache`.
- `activity_history_screen.dart` merges cached cloud history and local sessions by session ID. The database cannot be inspected here to confirm any rows exist.
- Retry restarts the preparation flow. Existing media is not explicitly skipped based on verified local file state in `OfflineCachePreparation`; downloads may be repeated.
- `OfflineStore.cacheMedia` writes a `.part` file, validates non-empty/expected byte count, then renames it. The manifest changes to `ready` only after `cacheMedia` returns and `mediaPath` verifies the file.
- Cognitive games load bundled JSON, so game questions/content do not require a network request. Activity writes are saved locally first and queue entries carry caregiver IDs. Sync checks current auth identity, caregiver-visible profile and enrolled device/revocation state before remote writes; retries use stable IDs and existing-row checks.
- Auth startup uses `Supabase.initialize` then `client.auth.currentUser`, with `onAuthStateChange` driving `AuthGate`. Whether a persisted refresh token can be refreshed offline/expired was not device-tested.

## Test case results

| ID | Requirement / method | Expected | Actual evidence | Status |
|---|---|---|---|---|
| A01 | Inspect DB path and DDL | App-private SQLite path; expected schema | `offline_store.dart` `database`; nine original tables plus four v2 tables | PASS (code inspection) |
| A02 | First-launch table/index creation | Tables/indexes create without errors | `onCreate` DDL inspected; no SQLite runtime harness | PARTIAL |
| A03 | Session/response/outbox atomicity | Related writes commit or roll back together | `createSession`, `saveResponses`, `finishSession` use `db.transaction` | PARTIAL; no injected-failure runtime test |
| A04 | Persistence across restart | Rows remain after app process restart | No device/local DB access | BLOCKED |
| A05 | Constraints/foreign keys | Referential integrity enforced | Several NOT NULL/PK constraints exist; no FK declarations | FAIL (foreign-key enforcement absent in inspected DDL) |
| A06 | Upgrade preserves existing rows | Additive upgrade, no destructive reset | v1→v2 `onUpgrade` creates tables only; no migration execution test | PARTIAL |
| A07 | Existing installed DB row counts | Report actual table counts | No ADB/device or DB file access | BLOCKED |
| B01 | Automatic cache trigger | Runs after authenticated online startup | `_loadData` starts `_prepareOfflineData`; connectivity stream retries | PARTIAL; no app runtime evidence |
| B02 | Caregiver/profile cache | Authorized rows cached and isolated by caregiver ID | caregiver row and profiles stored under owner ID; offline caregiver details not restored | PARTIAL |
| B03 | All decks/cards/media cache | Every authorized deck/card/media offline-ready | Code enumerates profiles/decks/cards/assets; network/download not exercised | PARTIAL |
| B04 | Bundled cognitive content | Both games load offline content | `rootBundle.loadString('assets/cognitive_games.json')` | PASS (code inspection only) |
| B05 | All historical sessions/responses | Complete history cached | Query capped at 500; no pagination | FAIL for unbounded “all history” requirement |
| B06 | Pending local activity preserved | Remains in owner-scoped tables/outbox | Separate pending `sessions`, `responses`, `sync_outbox`; cleanup protects non-synced records | PARTIAL; no restart test |
| C01 | Accurate progress | Progress tracks all cache work | Counter tracks profile/deck units, not media/card work | FAIL |
| C02 | Failure/retry visibility | Failed files identified and retryable | `cache_manifest` states and Retry button in main UI | PARTIAL; no injected failure/retry exercise |
| C03 | Partial cache not complete | Partial deck clearly unavailable/identified | Manifest records partial, but viewer does not consume manifest | FAIL |
| C04 | Interrupted/repeated downloads | Resume safely, no corruption | `.part`/rename protects completed file; interrupted app restart and duplicate transfer not exercised | PARTIAL |
| C05 | Cross-caregiver cache isolation | Other caregiver cannot read owner data | Reads query by caregiver ID; no multi-account runtime test | PARTIAL |
| D01 | Existing session restoration | Persisted Supabase session restores | `AuthGate` reads `currentUser` and listens to auth state | PARTIAL; runtime offline/expiry not tested |
| D02 | Password/token handling | No passwords in SQLite/report | No password storage in OfflineStore; auth delegated to Supabase SDK | PASS (code inspection) |
| D03 | Expired/invalid auth offline | Clear, secure re-auth behavior | No explicit expired-session UI test; unable to test | NOT TESTED |
| D04 | Online/offline sign-out and account switch | Local lock, pending warning, no cross-owner sync | Sign-out warns, stops sync, signs out, then clears synced cache; pending rows retain owner | PARTIAL; no runtime/auth integration test |
| E01 | Offline app launch/profile/decks | Previously cached UI opens without network | No physical-device test | BLOCKED |
| E02 | Offline Memory Deck/media/Recall-Reveal | Cached media available and story flow works offline | Media/player local path code exists; no device or asset cache to inspect | BLOCKED |
| E03 | Offline games and local records | Both games complete and persist offline | Bundled JSON and local writes found; no offline execution/restart test | BLOCKED |
| E04 | Offline history | Cached/local activity history appears | Source merges cached sessions, cached responses and pending local sessions | PARTIAL; no rows/runtime test |
| F01 | No network vs internet vs Supabase | Distinct truthful status states | `connectivity_plus`, external 204 probe, then Supabase caregiver query | FAIL: state wiring can misclassify; see risks below |
| F02 | Wi-Fi without internet / Supabase outage | Correct differentiated display | No network fault injection; external probe not exercised | BLOCKED |
| F03 | Connectivity restore retry | Sync/cache retry after reconnect | connectivity stream triggers `syncNow` and cache preparation | PARTIAL; not runtime-tested |
| G01 | Owner/profile/device authorization | Do not sync another owner or revoked device | Guards in `_syncSession`/`_syncResponse` and owner-filtered outbox | PARTIAL; no RLS integration test |
| G02 | Idempotency and duplicate prevention | Retry does not duplicate remote rows | Stable IDs and lookup-before-insert/confirmation paths inspected | PARTIAL; no cloud test |
| G03 | Interrupted sync/conflicting terminal status | Keep local data, retry safely | Per-record try/catch and status conflict error paths inspected | PARTIAL; no fault injection |
| G04 | Live Supabase persistence | Session/response appears exactly once | No isolated Supabase environment; production writes prohibited | BLOCKED |
| H01 | Sign-out confirmation/pending warning | Warn before sign-out | `_signOut` queries outbox counts and presents confirmation | PARTIAL; widget interaction not tested |
| H02 | Stop sync/sign-out/cache cleanup order | Stop sync; clear only after sign-out succeeds | `_signOut` ordering inspected; no async race test | PARTIAL |
| H03 | Pending data owner isolation during switch | A’s records never sync as B | Owner ID checked against current auth and outbox owner filter | PARTIAL; no account-switch device test |

## Automated test results

- `flutter test` — **PASS**, all 11 tests across existing game rules, navigation, and reporting.
- `flutter test --coverage` — **PASS**, all 11 tests; generated coverage output. Existing tests do not exercise offline storage/cache/sync paths.
- `flutter analyze` — **FAIL (tool exit 1)** due to 32 `info` diagnostics: curly-brace style notices and a deprecated form-field property. No analyzer error diagnostics appeared.
- No Phase 5-specific tests were present in `android_app/test`.

## SQLite and device test results

- Source-level DDL inspection only. No live SQLite file/table contents/counts could be inspected.
- No isolated SQLite transaction/migration tests were run; `sqflite` needs its supported test platform/database factory. No destructive tests were attempted.
- `adb` command was not available, so device model/Android version, install-preserving upgrade, logcat, airplane-mode tests, restart persistence, and media playback were not tested.

## Bugs and risks discovered

1. **Reachability status can be wrong** (`offline_sync.dart` `syncNow` / `snapshot`): `syncNow` updates `_online` from `connectivity_plus` but does not update `_hasNetwork`. When internet probing fails, it sets `_supabaseReachable = false`, so the snapshot selects `supabaseUnavailable`, conflating internet outage with Supabase outage. The “internet available” probe is a third-party Google connectivity-check endpoint; it was not exercised in this environment and may be filtered on some networks.
2. **History is incomplete for large accounts** (`offline_cache_preparation.dart` `prepare`): only the newest 500 sessions are selected and no pagination follows. Responses are requested in a single session-ID filter; backend request limits may further truncate large histories.
3. **Progress is not item-accurate** (`CachePreparationSnapshot`): total increments for profiles and decks, while media/card work is excluded. A deck may increment completion after a failed media item; the UI does not show a completed summary when there are zero failures.
4. **Partial content may appear available** (`cache_manifest` vs `elderly_memory_screen.dart`): deck readiness is saved as `partial`, but the memory viewer does not consult that manifest to label/restrict missing assets. Local media fallback may show a placeholder or unavailable audio without a deck-level offline warning.
5. **Caregiver cache is write-only for offline startup** (`main.dart` `_loadData`): caregiver details are persisted but not read when remote caregiver fetch fails.
6. **No runtime evidence for cached media or cache resume**: downloads and atomic rename are only source-inspected. Preparation restarts the routine after reconnection; completed files are not explicitly skipped before network download.
7. **SQLite has no foreign keys** in inspected DDL. Transactional code guards some relationships, but schema-level referential integrity is absent.
8. **Global status service lifecycle/race risk** (`OfflineSyncService` singleton): auth switching and an in-flight sync were not exercised. Current account checks reduce risk, but the service is a process singleton and does not expose a tested teardown/reinitialization path.

## Missing / blocked requirements

- Physical-device tests on the Motorola Edge 50 Fusion: offline cold restart, cached media display/playback, games, persistence, reconnection sync, online/offline sign-out and account switching.
- Safe live Supabase integration against an isolated test project to verify session/response idempotency and RLS.
- Actual SQLite record counts and installed database migration result.
- Network fault injection for captive portal, no internet, Supabase unreachable, interrupted downloads, and interrupted synchronization.
- Full activity history pagination; accurate per-item cache progress; user-visible partial-cache handling; caregiver-profile offline restore.

## Overall decision

**INCONCLUSIVE.** The unit suite passes, but no physical Android or live backend evidence is available, and static inspection identified gaps in cache completeness and connectivity-state accuracy. Phase 5 should not be accepted until the listed implementation gaps are addressed and the required physical-device and isolated-backend scenarios pass.
