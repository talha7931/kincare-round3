# KinCare — Shared API and Domain Contracts

**Status:** Contract baseline; update when the backend migration is reviewed and merged.  
**Rule:** Android and PWA may use different Supabase SDKs, but must implement identical business rules, table names and payload semantics.

## Authentication

- Supabase Auth caregiver account is the identity source.
- `CAREGIVERS.id` equals `auth.users.id`.
- Elderly profile selection is a caregiver-authorized context switch, not a separate elderly login.
- Every profile operation must be constrained by the authenticated caregiver's ownership through RLS.

## Core entities

Use the exact fields and relationships in `docs/KINCARE_ROUND3_MASTER_SPEC.md`, section 7. Any additional field must be introduced through a reviewed migration and reflected in this document.

## Stable activity response payloads

Use JSON objects with a version field so clients can evolve safely. The Phase 3 games use these payloads and the existing `response_index` / `is_correct` columns:

```json
{
  "schema_version": 1,
  "activity_type": "odd_one_out",
  "round_id": "fruit-chair",
  "selected_item_id": "chair",
  "expected_item_id": "chair"
}
```

```json
{
  "schema_version": 1,
  "activity_type": "everyday_object_sorting",
  "item_id": "apple",
  "selected_category_id": "fruit",
  "expected_category_id": "fruit"
}
```

Odd One Out writes one response per round; `response_index` is the zero-based
round index and `is_correct` records whether the selected item matches the
round's expected item. Everyday Object Sorting writes one response per object
when the elderly user confirms the completed sort; `response_index` is the
zero-based object index and `is_correct` records whether its final category
matches the intended category. Sorting choices remain editable in local screen
state until the user finishes, so corrections do not overwrite append-only
cloud responses.

Both games use the existing `ACTIVITY_TYPES.stable_key` values
`odd_one_out` and `everyday_object_sorting`. A session references the active
profile and a caregiver-owned `ENROLLED_DEVICES` row. No Phase 3 schema changes
are required.

```json
{
  "schema_version": 1,
  "activity_type": "memory_deck",
  "response_kind": "audio",
  "text": null
}
```

For recorded audio, store the file in private Supabase Storage and link it through `ACTIVITY_RESPONSES.response_audio_asset_id`. Do not put a long-lived public URL in `response_payload`.

## Memory Deck contract

- A deck belongs to exactly one elderly profile.
- `created_by_caregiver_id` records the caregiver who created it.
- A card belongs to one deck.
- A card references separate photo, question-audio and answer-audio media asset IDs.
- Question and answer text remain available even if optional audio is unavailable.

## Reporting contract

The report query/model must include the selected elderly profile, reporting period, sessions, activity types, statuses, recorded responses and caregiver observations. It must also expose pending-local-sync status where relevant, because the cloud may not yet contain all local data.

## Dashboard aggregation definitions

- Total sessions: count of sessions in the selected profile/date range, excluding locally pending records only when the dashboard is explicitly cloud-only; otherwise label local vs synced totals.
- Sessions by activity: count grouped by activity type.
- Participation days: distinct local calendar dates with at least one session, using a documented timezone rule.
- Completion rate: completed sessions divided by all sessions with a known final status; do not treat in-progress/unknown as failed.
- Correctness: display only for structured activities where `is_correct` is meaningful. Never score open-ended Memory Deck reminiscence.

## Sync contract

- Client-generated UUIDs for offline-created records.
- Upsert/idempotent cloud writes keyed by stable IDs.
- Upload binary media before inserting/updating metadata rows that reference the uploaded file.
- Session/response records are append-only for the MVP.
- Store sync state locally: `pending`, `syncing`, `synced`, `failed`.
- Never mark synced until the server confirms the write.
