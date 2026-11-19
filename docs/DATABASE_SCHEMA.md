# KinCare — Database Schema Snapshot

The full schema rules and rationale are in `docs/KINCARE_ROUND3_MASTER_SPEC.md`, section 7. The reviewed SQL migrations in `supabase/migrations/` become the executable source of truth.

## Tables

| Table | Purpose | Key ownership/relationship |
|---|---|---|
| `auth.users` | Supabase-managed authentication | Caregiver identity |
| `CAREGIVERS` | Caregiver application profile | `id` equals `auth.users.id` |
| `ELDERLY_PROFILES` | Multiple elderly profiles per caregiver | `caregiver_id` FK; not unique |
| `ENROLLED_DEVICES` | Devices enrolled by a caregiver | `caregiver_id` FK; no elderly profile FK |
| `ACTIVITY_TYPES` | Activity type lookup | Seeds Memory Decks, Odd One Out, Object Sorting |
| `ACTIVITY_SESSIONS` | One activity attempt/session | References elderly profile, activity type and device; optional memory deck |
| `ACTIVITY_RESPONSES` | Per-session answers/interactions | References session; optional memory card; correctness nullable |
| `MEMORY_DECKS` | Profile-specific photo/story deck | References elderly profile and `created_by_caregiver_id` |
| `MEMORY_CARDS` | Individual card in a deck | Has own `id`; references deck/photo/question audio/answer audio |
| `MEDIA_ASSETS` | Metadata for stored media | References elderly profile and uploading caregiver; actual bytes in private Storage |

## Critical design rules

- One caregiver owns many elderly profiles and many enrolled devices.
- A shared enrolled device can be used by multiple profiles of its caregiver.
- Every activity session identifies both the active elderly profile and the device.
- Do not add a direct `elderly_profile_id` to `ENROLLED_DEVICES`.
- Do not make `ELDERLY_PROFILES.caregiver_id` unique.
- Add nullable `ACTIVITY_RESPONSES.response_audio_asset_id` FK to `MEDIA_ASSETS` to persist recorded verbal responses.
- `is_correct` is nullable; open-ended memory responses are not marked wrong.
- Apply RLS through parent ownership relationships.
