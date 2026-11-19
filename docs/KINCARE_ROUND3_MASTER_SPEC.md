# KinCare Round 3 — Master Product & Technical Specification

**Project:** KinCare — Care Beyond Connectivity  
**Competition:** PRASUNEX Innovathon 2026 — Round 3: Prototype Development & Demonstration  
**Development/submission period:** 18 November 2026, 09:00 IST – 25 November 2026, 23:00 IST  
**Shortlisting results:** 27 November 2026  
**Status:** MVP specification — source of truth for all contributors and AI coding agents  
**Version:** 1.0

> This document defines what the Round 3 prototype must demonstrate. It separates committed MVP behaviour from future scope. Where a design decision is not finalised, it is marked as an implementation decision and must be recorded here before agents build conflicting alternatives.

---

## 1. Product vision

KinCare is an offline-first cognitive engagement and caregiver-support platform for older adults, including people living with dementia, and their family caregivers. It is designed for households and communities where internet access may be unreliable.

KinCare provides personalised, familiar-photo-based engagement, simple cognitive activities, caregiver-managed profiles and activity records. Caregivers can review engagement history and prepare factual activity summaries to share during healthcare consultations.

KinCare is **not** a diagnostic, treatment or clinical cognitive-assessment product. It does not diagnose dementia, measure clinical cognitive ability, claim to slow disease progression or replace healthcare professionals.

### Round 3 objective

Deliver a working prototype/MVP that demonstrates the core KinCare journey on **both**:

1. **Android application:** Flutter + Dart.
2. **Progressive Web Application (PWA):** React + TypeScript.

Both applications must use one shared Supabase backend, support the same core user journeys and implement their own platform-appropriate offline storage.

Neither platform is an elderly-only or caregiver-only product. Both must offer caregiver and elderly-user functionality.

---

## 2. Official Round 3 submission and evaluation

The organiser's Round 3 instructions require:

- Working prototype, MVP or proof of concept.
- Live demonstration or demonstration video, as instructed.
- Source code or repository link, where applicable.
- Brief technical documentation.
- Explanation of implemented features and limitations.
- Future development plans and potential improvements.

Evaluation criteria:

- Functionality and implementation quality.
- Technical execution.
- User experience and usability.
- Innovation and effectiveness.
- Practical applicability and scalability.
- Quality of demonstration.

**Submission format is not assumed.** Confirm the portal's accepted file types, APK/URL expectations, repository access and video requirements with the official Round 3 portal/organisers. Prepare the deliverables listed in `docs/SUBMISSION_CHECKLIST.md`.

---

## 3. Product principles and non-negotiable decisions

1. **Two complete clients:** Android and PWA both provide caregiver and elderly functionality for the core MVP journeys.
2. **One backend:** Both clients connect to the same Supabase project and schema.
3. **One business-rule source:** Shared rules are documented here; no agent may invent different behaviour for one platform.
4. **One design system:** Forest/sage colour palette, consistent language, common interaction patterns and accessible typography. Native layouts may differ where appropriate.
5. **Separate local stores:** Android uses SQLite plus local media files/cache. PWA uses IndexedDB plus Cache API/service worker and browser-managed media storage.
6. **Offline-first:** Activities and previously downloaded content remain usable offline. New cloud-only actions wait until connectivity returns.
7. **Append-only activity history:** Activity sessions and responses are recorded; don't silently overwrite user history.
8. **Caregiver-controlled profiles:** Elderly people do not have individual login accounts in this MVP.
9. **Honest reporting:** Reports describe recorded engagement and caregiver observations, not clinical conclusions.
10. **No fake functionality:** A button must work or be visibly marked unavailable/not implemented. Do not use hard-coded demo metrics in a live dashboard.
11. **No false completion claims:** A feature is implemented only after its acceptance test passes on the target platform.
12. **Protect delivery time:** Freeze new features by 23 November where possible; reserve 24–25 November for integration, verification, documentation and submission.

---

## 4. Users, roles and access model

### 4.1 Caregiver

- Registers/logs in using Supabase Auth.
- Owns one caregiver account and can manage multiple elderly profiles.
- Creates and manages Memory Decks for profiles they own.
- Uploads photos, context, question text and audio assets.
- Reviews activity sessions, responses and summaries.
- Adds caregiver observations to a report.
- Can use the activities as well as manage the platform.

### 4.2 Elderly user

- Does not have an independent login in the MVP.
- Uses a caregiver-authenticated/enrolled device or an active caregiver session.
- Is selected as the active profile before an activity session begins.
- Can use Memory Decks, Odd One Out and Everyday Object Sorting.
- Can respond verbally where the microphone is available and permission is granted.

### 4.3 Multiple profiles and devices

- One caregiver can own multiple elderly profiles.
- One caregiver can enroll multiple devices.
- An enrolled device can be shared by the caregiver's elderly profiles.
- A device is linked to the caregiver, **not** permanently linked to one elderly profile.
- Every activity session must record both the selected `elderly_profile_id` and the `device_id` that created it.
- The client must verify that the selected profile belongs to the authenticated caregiver before creating a session.

---

## 5. Feature scope — both Android and PWA

All features below are required on both clients unless a platform limitation is explicitly documented and approved. UI layout may adapt to screen size, but do not split the product into an Android elderly app and a caregiver-only PWA.

### 5.1 Authentication and onboarding

- Caregiver sign-up, sign-in, sign-out and session restoration through Supabase Auth.
- Create/link the `CAREGIVERS` application profile using the authenticated Supabase user UUID.
- Create, edit, view and select multiple elderly profiles.
- Basic device registration/enrolment and revocation status, to the extent supported safely in the MVP.
- Clear active-profile indicator before entering an activity.
- Do not store passwords in application tables or local app databases.

### 5.2 Memory Decks — central personalised feature

Caregiver workflow:

1. Select an elderly profile.
2. Create a Memory Deck with title and language.
3. Upload a meaningful family photograph.
4. Add a description/personal context.
5. Enter a question, for example “Who is in this photograph?”
6. Add caregiver-provided answer/context text.
7. Record or upload question audio and answer/context audio; if audio creation is unavailable in a specific environment, show a clear fallback and retain the text. Audio playback must be available offline after the asset has been downloaded/cached.
8. Save and preview the card.

Elderly workflow:

1. Select the active elderly profile.
2. Open an available Memory Deck.
3. View the photo and hear the question.
4. Respond verbally using in-app audio recording where microphone permission is available.
5. Hear the caregiver-provided answer/context audio or read the context text.
6. Save the response locally and attach it to the correct session/card.

Rules:

- Memory Decks belong to an elderly profile and record which caregiver created them.
- Each Memory Card has its own primary key and references its deck and media assets.
- A reminiscence response is open-ended. Do not mark it wrong merely because it differs from the caregiver's wording.
- Audio recording and upload must be permission-aware, with a text fallback.
- Do not claim automatic speech recognition/transcription unless it is actually implemented and tested. Audio recording is sufficient for the MVP.

### 5.3 Odd One Out

- Display a small set of familiar images/items.
- User selects the item that differs.
- Record the selected item, expected answer where applicable, response time if practical, and session completion.
- `is_correct` may be recorded for this structured activity.
- Provide simple visual feedback and accessible touch targets.

### 5.4 Everyday Object Sorting

- Display familiar everyday objects and clear category/group targets.
- User moves/selects objects into categories.
- Provide spoken instructions or cached audio guidance.
- Record each placement/response and session completion.
- Use accessible drag/drop alternatives (tap object, then tap category) so the activity remains usable on different screens and for users with limited dexterity.

### 5.5 Caregiver dashboard and progress monitoring

Both clients must provide a usable dashboard for the selected profile, including:

- Total sessions in the selected date range.
- Sessions by activity type.
- Dates of participation and recent activity history.
- Completed/incomplete sessions where status is known.
- Responses for individual sessions/cards.
- Memory Deck participation history.
- Sync status: pending, synced or failed, with last successful sync time where available.
- Caregiver-entered observations/notes.

Do not invent activity counts, scores or progress. All dashboard figures must be derived from stored records. Clearly label an empty state when no activity has been recorded.

### 5.6 Healthcare consultation activity summary (PDF)

Both applications must provide a way to generate/export a profile-specific activity summary for a selected reporting period. This is a factual engagement report for the caregiver to share during a healthcare consultation; it is not a clinical report.

Minimum PDF contents:

- KinCare title and report generation date.
- Elderly profile display name (avoid unnecessary sensitive identifiers).
- Caregiver display name, if available.
- Reporting period.
- Total recorded sessions and breakdown by activity type.
- Session dates and completion statuses.
- Available response/participation summaries.
- Caregiver observations/notes, clearly attributed as caregiver-entered.
- Data coverage/sync note if some records are still pending locally or the report is based on partial data.
- Disclaimer: “This report summarises application activity and caregiver-entered observations. It is not a diagnostic or clinical cognitive assessment and should be interpreted by a qualified healthcare professional.”

Do not include a dementia severity score, diagnostic label, clinical cognitive score or unvalidated claim of improvement. Do not describe game accuracy as a clinical measure.

### 5.7 Caregiver wellbeing resources

- Include a small, curated section of practical caregiver self-care and support information.
- Make the content accessible offline.
- Label it as general informational support, not therapy or a substitute for professional help.

### 5.8 Language and audio

- Data model supports a language code per Memory Deck/profile/content item.
- Aim to demonstrate English, Hindi and Marathi prompt/content capability if suitable audio/text assets are available within the build window.
- Prefer pre-recorded/cached audio for reliable offline playback.
- Device text-to-speech can be an optional fallback, but offline voice availability varies by device and installed voice packs. Do not guarantee it without device testing.
- If full UI translation cannot be completed, document exactly which UI and audio languages are implemented.

---

## 6. Technical architecture

### 6.1 Android client

- Flutter + Dart.
- Supabase Flutter client for authentication and cloud data access.
- SQLite for structured offline data and pending-change queue.
- App-private local file storage for cached/downloaded media and recorded responses.
- Connectivity awareness and manual “Sync Now”.
- Automatic sync attempt on app launch/resume and when connectivity returns while app is active. Do not promise unrestricted background execution unless implemented and verified on Android.

### 6.2 PWA client

- React + TypeScript (Vite is acceptable).
- Installable web app via Web App Manifest.
- Service Worker for application shell/static asset caching and offline request handling.
- Cache API for application assets and suitable media caching.
- IndexedDB for structured offline records, activity outbox and local metadata.
- Browser-managed persistent storage where available; handle quota/eviction gracefully.
- Manual “Sync Now” and sync attempts on app launch/foreground/reconnection.
- Do not assume Background Sync is supported everywhere. The app must remain correct when sync only occurs while the PWA is open.
- Serve the deployed PWA over HTTPS; localhost is acceptable for development.

### 6.3 Shared cloud backend

Supabase provides:

- Auth: caregiver identity.
- PostgreSQL: profiles, decks, cards, sessions, responses, media metadata and device records.
- Storage: private photos and audio files.
- Row Level Security (RLS): caregiver ownership enforcement.

Both clients use public/anon client configuration protected by RLS. **Never put the Supabase service-role key in Flutter, React, source control, APKs or browser bundles.**

### 6.4 Repository structure

```text
KinCare/
├── android_app/                 # Flutter Android client
├── pwa/                         # React + TypeScript PWA
├── supabase/
│   ├── migrations/              # Ordered SQL migrations
│   ├── seed.sql                 # Safe demo content only
│   └── config.toml              # If Supabase CLI is used
├── docs/
│   ├── KINCARE_ROUND3_MASTER_SPEC.md
│   ├── DATABASE_SCHEMA.md
│   ├── API_CONTRACTS.md
│   ├── OFFLINE_SYNC.md
│   ├── SECURITY_PRIVACY.md
│   ├── TEST_PLAN.md
│   ├── IMPLEMENTED_FEATURES_AND_LIMITATIONS.md
│   ├── SUBMISSION_CHECKLIST.md
│   └── AGENT_WORKFLOW.md
├── assets/                      # Approved shared design/media assets
├── demo/                        # Demo script, screenshots and recording plan
├── .github/
│   └── copilot-instructions.md
├── .cursor/
│   └── rules/
│       └── kincare.mdc
├── AGENTS.md
├── README.md
└── .gitignore
```

The single copy of this master spec should live at `docs/KINCARE_ROUND3_MASTER_SPEC.md` in the actual repository. The supplied root copy is convenient during initial setup; move/copy it to the documented location and update links once the repository is created.

---

## 7. Database design — agreed logical schema

The SQL migration is the executable source of truth once reviewed and merged. Keep table and column names consistent across clients, SQL, documentation and generated types.

### 7.1 Supabase-managed authentication

**AUTH_USERS** is Supabase's managed `auth.users` table, not an application-created password table.

- `id` — UUID primary key.
- `email` — managed by Supabase Auth.
- Passwords are managed securely by Supabase Auth; they are not copied into `CAREGIVERS`.

### 7.2 Application tables

#### CAREGIVERS

- `id` — UUID primary key; same UUID as `auth.users.id` (one-to-one application profile).
- `display_name`.
- `created_at`.

#### ELDERLY_PROFILES

- `id` — UUID primary key.
- `caregiver_id` — FK to `CAREGIVERS.id`; **not unique** (one caregiver owns many profiles).
- `display_name`.
- `preferred_language` (or agreed language-code field).
- Additional profile fields only when required by the existing ERD/product need; avoid collecting unnecessary health or identity data.

#### ENROLLED_DEVICES

- `id` — UUID primary key.
- `caregiver_id` — FK to `CAREGIVERS.id`.
- `device_uuid` — unique device identifier.
- `device_name`.
- `enrolled_at`, `last_seen_at`, `revoked_at`.
- There is no `elderly_profile_id` here because one caregiver-owned device can be shared across that caregiver's profiles.

#### ACTIVITY_TYPES

- `id` — primary key.
- `name`/stable key and description.
- Seed the three MVP activity types: Memory Decks, Odd One Out, Everyday Object Sorting.

#### MEMORY_DECKS

- `id` — UUID primary key.
- `elderly_profile_id` — FK to `ELDERLY_PROFILES.id`.
- `created_by_caregiver_id` — FK to `CAREGIVERS.id`.
- `title`.
- `language_code`.
- `created_at`; add `updated_at` if edit/sync conflict handling needs it.

#### MEDIA_ASSETS

- `id` — UUID primary key.
- `elderly_profile_id` — FK to `ELDERLY_PROFILES.id`.
- `uploaded_by_caregiver_id` — FK to `CAREGIVERS.id`.
- `storage_bucket`, `storage_path`.
- `media_type`, `mime_type`.
- `created_at`.
- This table stores metadata/references only; binary photos and audio are in Supabase Storage.

#### MEMORY_CARDS

- `id` — UUID primary key.
- `deck_id` — FK to `MEMORY_DECKS.id`.
- `photo_asset_id` — FK to `MEDIA_ASSETS.id`.
- `question_audio_asset_id` — nullable FK to `MEDIA_ASSETS.id`.
- `answer_audio_asset_id` — nullable FK to `MEDIA_ASSETS.id`.
- `question_text`.
- `answer_context`.
- `display_order`.
- Keep the three media-asset relationships distinct in SQL and documentation.

#### ACTIVITY_SESSIONS

- `id` — UUID primary key.
- `elderly_profile_id` — FK to `ELDERLY_PROFILES.id`.
- `activity_type_id` — FK to `ACTIVITY_TYPES.id`.
- `device_id` — FK to `ENROLLED_DEVICES.id`.
- `memory_deck_id` — nullable FK to `MEMORY_DECKS.id`, used for Memory Deck sessions.
- `started_at`, `completed_at` (nullable until completed), `status`, `created_at`.
- Do not add a redundant `caregiver_id` unless a specific query/security need is documented; ownership can be checked through the elderly profile.

#### ACTIVITY_RESPONSES

- `id` — UUID primary key.
- `session_id` — FK to `ACTIVITY_SESSIONS.id`.
- `memory_card_id` — nullable FK to `MEMORY_CARDS.id`.
- `response_index`.
- `response_payload` — structured text/selection/result payload; document a stable JSON shape per activity type.
- `is_correct` — nullable; meaningful for structured games, not open-ended reminiscence.
- `responded_at`.
- **MVP extension required for captured verbal responses:** add nullable `response_audio_asset_id` FK to `MEDIA_ASSETS.id` so a recorded response can be uploaded and linked without placing a storage URL directly in the response payload. If the team chooses not to persist audio for a particular flow, record that limitation honestly.

### 7.3 Relationships and cardinalities

- AUTH_USERS 1 — 0/1 CAREGIVERS.
- CAREGIVERS 1 — many ELDERLY_PROFILES.
- CAREGIVERS 1 — many ENROLLED_DEVICES.
- CAREGIVERS 1 — many MEMORY_DECKS through `created_by_caregiver_id`.
- ELDERLY_PROFILES 1 — many MEMORY_DECKS.
- MEMORY_DECKS 1 — many MEMORY_CARDS.
- ELDERLY_PROFILES 1 — many MEDIA_ASSETS.
- CAREGIVERS 1 — many MEDIA_ASSETS through `uploaded_by_caregiver_id`.
- MEDIA_ASSETS may be referenced by many cards in distinct photo/question-audio/answer-audio roles.
- ELDERLY_PROFILES 1 — many ACTIVITY_SESSIONS.
- ACTIVITY_TYPES 1 — many ACTIVITY_SESSIONS.
- ENROLLED_DEVICES 1 — many ACTIVITY_SESSIONS.
- MEMORY_DECKS 0/1 — many ACTIVITY_SESSIONS (nullable deck reference on a session).
- ACTIVITY_SESSIONS 1 — many ACTIVITY_RESPONSES.
- MEMORY_CARDS 0/1 — many ACTIVITY_RESPONSES.

### 7.4 Schema rules

- `ELDERLY_PROFILES.caregiver_id` must not be unique.
- Do not link an enrolled device directly to only one elderly profile.
- Do link each session to both a selected profile and enrolled device.
- Every child record must be ownership-checked through its parent relationships in RLS.
- Use UUIDs generated on the client for offline-created rows where needed, then upsert idempotently on sync.
- Use foreign keys, indexes and `NOT NULL` constraints deliberately; do not create arbitrary duplicate ownership fields.
- Any schema change requires a migration, documentation update and cross-client review before merge.

---

## 8. API and data contracts

Both clients may use their platform's Supabase SDK, but they must implement the same domain-level behaviour and use the same table/column names.

Create and maintain `docs/API_CONTRACTS.md` with:

- Authentication/session contract.
- Profile CRUD and profile ownership rules.
- Device enrolment contract.
- Memory Deck/card CRUD contract.
- Media upload/download contract.
- Activity session/response contract.
- Dashboard aggregation definitions.
- Report export data model.
- Sync payload/order, retry and idempotency rules.

Do not let Android and PWA independently define incompatible JSON shapes for `response_payload`. Suggested stable payloads:

- Odd One Out: `{ "selected_item_id": "...", "expected_item_id": "..." }`.
- Object Sorting: `{ "placements": [{ "item_id": "...", "category_id": "..." }] }`.
- Memory Deck response: `{ "response_kind": "audio|text", "text": null }`; audio file is linked through `response_audio_asset_id`.

These are logical examples; final field names/types must be documented and used identically by both clients.

---

## 9. Offline and synchronization design

### 9.1 Local-first behaviour

- The user can open the installed app and launch previously downloaded/cached content offline.
- Previously downloaded Memory Deck photos/audio and the three activity definitions are available offline.
- New activity sessions/responses are saved locally first.
- Each local mutation has a stable UUID and a sync state such as `pending`, `syncing`, `synced` or `failed`.
- The UI shows the sync state and provides a manual Sync Now action.
- When online, pending changes are uploaded and marked synced only after successful acknowledgement.

### 9.2 Sync queue and ordering

Recommended sync order:

1. Validate caregiver session and enrolled-device ownership.
2. Upload pending media files to the private Storage bucket.
3. Upsert MEDIA_ASSETS metadata.
4. Upsert any pending Memory Deck/card metadata after referenced media IDs exist.
5. Upsert activity sessions.
6. Upsert activity responses and response-audio references.
7. Refresh server-side data and update local sync status.

Use retry with bounded backoff. A failed upload must remain pending/failed and visible for retry; it must not be silently discarded. Use idempotent upserts and stable client-generated UUIDs to prevent duplicate records after retries.

### 9.3 Conflict handling

- Activity sessions/responses are append-only; don't overwrite prior responses during sync.
- Mutable profile/deck edits may use a documented `updated_at`/last-write-wins rule for the MVP, with conflict visibility where practical.
- Do not implement destructive hard deletes in an offline queue without a reviewed deletion/tombstone strategy.
- Device/profile ownership must be revalidated on the server through RLS and safe relationship checks.

### 9.4 Offline media

- Download/cache required deck photos/audio before advertising a deck as available offline.
- Keep local file identifiers/paths in platform-local storage; cloud rows store Storage bucket/path metadata.
- Track media download/upload state separately from structured rows.
- Handle insufficient device/browser storage gracefully.

---

## 10. Security and privacy

- Caregiver authentication uses Supabase Auth.
- `CAREGIVERS.id` equals the authenticated `auth.users.id` UUID.
- RLS restricts caregiver access to their own profiles and all descendants.
- Private Storage bucket; policies must ensure only the owning caregiver can upload/read the profile's media.
- Never expose the service-role key or database password in client code, commits, APK or PWA bundle.
- Use environment variables for public project URL/anon key and exclude local secret files from Git.
- Request microphone/photo permissions only when needed and explain the purpose.
- Provide a way to remove locally cached data at sign-out or when a profile/device is revoked, subject to safe pending-sync handling.
- Avoid collecting date of birth, diagnosis or medical records unless required and explicitly approved. Minimum data collection is preferred.
- Use HTTPS/TLS for network transfers.
- Do not claim end-to-end encryption or special local encryption unless implemented and tested.

---

## 11. Design system and usability

Use the established KinCare visual identity:

- Forest Green `#183D35`.
- Sage Green `#477568`.
- Warm Off-White `#F4F4F3`.
- White `#FFFFFF`.
- Pale Sage `#E5EEE8`.
- Cloud Blue-Grey `#E2E9ED`.
- Muted Amber `#D9A45B`.
- Charcoal `#263238`.

Design goals:

- Calm, warm, reassuring and uncluttered.
- Elderly interface: large buttons, high contrast, readable type, limited choices per screen, clear audio controls and predictable navigation.
- Caregiver interface: efficient profile management, clear activity history and useful report actions.
- Responsive layout on PWA; touch-friendly layout on Android.
- Accessibility: semantic labels, adequate contrast, scalable text where feasible, and alternatives to drag-only actions.
- Use the same terminology, activity names, icons and interaction logic on both clients.

---

## 12. Testing and acceptance criteria

A feature is complete only when the relevant tests pass. See `docs/TEST_PLAN.md` for the detailed test matrix.

### Mandatory end-to-end journey on BOTH clients

1. Caregiver signs in.
2. Caregiver creates/selects an elderly profile.
3. Caregiver creates a Memory Deck and adds at least one photograph, context, question and answer/audio asset.
4. Elderly user plays that deck and a verbal response is recorded where permitted.
5. User completes Odd One Out.
6. User completes Everyday Object Sorting.
7. Session/response records are stored locally.
8. Caregiver opens the dashboard and sees the records after sync.
9. Caregiver creates and exports the healthcare activity summary PDF.

### Offline test on BOTH clients

1. While online, sign in and download/cache a test profile's deck and game content.
2. Turn off network access.
3. Reopen/reload the app and verify it launches (for PWA, test installed PWA and offline refresh).
4. Play a cached deck/game and create an activity record.
5. Verify record remains after app/browser restart while offline.
6. Restore network and tap Sync Now.
7. Verify the cloud contains the record exactly once.
8. Open the other client and verify the synchronized record is visible after refresh.
9. Confirm the report reflects synced records and clearly indicates any pending local data.

### Security tests

- Caregiver A cannot read/update Caregiver B's profiles, decks, sessions or media.
- A session cannot be created for a profile owned by another caregiver.
- A revoked device cannot continue synchronizing.
- Client bundle does not contain service-role secrets.

### Demo quality

- Use one prepared test caregiver and a sample elderly profile with consent-safe synthetic/family demo photos.
- Use realistic sample content, never expose real health records.
- Capture a short, reliable recording of the entire workflow as backup to live demonstration.
- Have a network-off demonstration prepared, with all required assets cached ahead of time.

---

## 13. Seven-day delivery priorities

Time is constrained by college examinations. Prefer narrow, complete vertical slices instead of building many disconnected screens.

### P0 — Must be demonstrable

- Shared Supabase schema, Auth and RLS.
- Caregiver account and multiple elderly profiles.
- Complete Memory Deck photo/context/question/answer workflow.
- All three cognitive activities.
- Activity session and response recording, including audio response capture where permissions allow.
- Caregiver dashboard and activity history.
- Profile-specific healthcare activity summary PDF.
- Working offline local storage and a tested sync round-trip on both clients.
- Both clients support the same core journey.

### P1 — Include if time allows after P0 works

- Rich participation charts and filters.
- Full English/Hindi/Marathi UI translation.
- More comprehensive device management.
- Advanced conflict-resolution UI.
- Additional caregiver wellbeing resources.
- Polished onboarding animations and advanced analytics.

### Future scope — not required for this prototype

- Time Credits marketplace/redeemable service network.
- Clinical screening, scoring or diagnostic functionality (not a KinCare goal).
- AI-generated cognitive interpretation.
- Integrations with hospital systems or electronic health records.
- Large-scale NGO/institution tenant administration.
- Advanced speech recognition/transcription.
- Multi-region production deployment and enterprise operations.

### Freeze rule

By 23 November, avoid starting new P0/P1 features unless they fix a blocker. Use 24–25 November primarily for integration, data/security checks, final builds, documentation, demo recording and submission.

---

## 14. Definition of done

A release candidate is ready only when:

- Both Android and PWA build and launch.
- Both connect to the same Supabase project.
- The same caregiver can sign in and see the same profile data in both clients.
- The same Memory Deck data/media is accessible in both clients after sync.
- All three activities record sessions and responses.
- Caregiver dashboard uses actual stored data.
- PDF summary exports correctly and carries the non-clinical disclaimer.
- Offline test and sync round-trip pass on both platforms.
- RLS ownership tests pass.
- No service-role secret is present in client artifacts or Git history.
- README and technical documentation match the shipped code.
- Known limitations are documented.
- APK/PWA URL/source repository and demo artefacts are ready according to organiser instructions.

---

## 15. Change-control rules

Any proposed change to core scope, database schema, cross-platform contract, ownership model or offline rules must:

1. State the reason and affected features.
2. Identify Android, PWA, backend and documentation impacts.
3. Update the relevant migration and contract/spec documents.
4. Be reviewed before implementation by the project owner.
5. Be tested on both clients before marking complete.

**Do not silently remove, rename or redesign previously agreed tables, fields, workflows or features.**
