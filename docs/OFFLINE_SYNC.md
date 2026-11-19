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

- Idempotent upserts using stable UUIDs.
- Retry with bounded backoff and visible failed state.
- Never silently drop pending data.
- Do not overwrite append-only session/response history.
- Cache only what is needed and handle storage quota/eviction.
- A report must disclose when local pending records are not yet included in the cloud-generated data.

## Minimum test

Complete an activity offline, close/reopen the app offline, verify the record remains, reconnect, sync, verify it appears exactly once in Supabase and then appears in the other client.
