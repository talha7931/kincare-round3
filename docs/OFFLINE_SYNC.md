# KinCare — Offline Storage and Synchronization Plan

## Platform-specific local storage

| Concern | Flutter Android | React PWA |
|---|---|---|
| Structured records | SQLite | IndexedDB |
| Application shell | Native installation | Service Worker + Cache API |
| Media | App-private local files/cache | Cache API/browser-managed storage/IndexedDB blobs where appropriate |
| Pending changes | SQLite outbox | IndexedDB outbox |
| Manual sync | Sync Now | Sync Now |

## Offline user journey

1. Caregiver signs in while online and selects a profile.
2. Download/caches the chosen Memory Deck's photos/audio and required game assets.
3. User can play cached activities offline.
4. Each session/response is written to local storage first with a client-generated UUID.
5. Pending records remain visible in local history and carry a pending sync status.
6. When connectivity is restored, the client retries synchronization.
7. Upload media first, then media metadata, then decks/cards or sessions/responses that reference it.
8. Mark each local item synced only after server acknowledgement.
9. Refresh cloud data; the other client can see records after it refreshes/synchronizes.

## Trigger policy

- Manual Sync Now.
- On app/PWA launch or foreground/resume.
- On network reconnection while app is active.
- Do not promise guaranteed background synchronization on all browsers. A PWA must remain correct if sync occurs only while it is open.

## Reliability rules

- Client-generated UUIDs are stable across retries. The clients first look up an existing session by ID and validate its profile/device ownership before updating it; responses are insert-only and a matching existing response ID is treated as already saved.
- Retry with bounded backoff and visible failed state.
- Never silently drop pending data.
- Do not overwrite append-only session/response history.
- Cache only what is needed and handle storage quota/eviction.
- A report must disclose when local pending records are not yet included in the cloud-generated data.
- Before queued activity sync, the authenticated caregiver, profile access, enrolled device and device revocation state are checked through the existing Supabase policies. Failed checks leave the local records queued for review/retry.
- On caregiver sign-out, active synchronization is stopped, then synced local activity and cached profiles/decks/cards/media/device metadata are cleared. Unsynced sessions and responses remain on-device so a transient sign-out does not erase activity. A different caregiver cannot sync those records.
- Memory Deck content and media are cached after successful online access; storage quota failures do not prevent the currently online deck from opening. Only decks and media already downloaded can be used offline.

## Current Phase 5 limits

- Activity sessions and responses queue offline. Memory Deck creation/editing, profile management, and media uploads still require connectivity.
- A device must have been enrolled while online before its offline sessions can be synced.
- Browser/PWA synchronization runs while the app is open or returns to the foreground; browsers do not guarantee background sync.
- Local pending records are shown in activity history with their sync state. Phase 4 dashboards and PDFs summarize cloud-synced activity only.
- The implementation adds no Supabase schema or RLS changes. Session completion uses the existing session update policy; response rows are never updated.

## Minimum test

Complete an activity offline, close/reopen the app offline, verify the record remains, reconnect, sync, verify it appears exactly once in Supabase and then appears in the other client. Also verify that sign-out removes synced cached content but retains pending records, and that revoked devices or inaccessible profiles cannot sync.
