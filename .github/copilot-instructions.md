# KinCare repository instructions

Read `AGENTS.md` and `docs/KINCARE_ROUND3_MASTER_SPEC.md` before coding. The master spec is the source of truth for product scope, shared business rules, database model, offline behaviour and acceptance criteria.

Build two equivalent core clients: Flutter/Dart Android and React/TypeScript PWA. Both must support caregiver and elderly journeys and use one shared Supabase project/schema. Do not split caregiver features into PWA-only or elderly features into Android-only.

Key invariants: caregiver accounts use Supabase Auth; elderly profiles have no individual login; one caregiver may own many profiles and devices; devices belong to caregivers, not a single profile; every activity session references both elderly profile and device; Memory Decks retain `created_by_caregiver_id`; Memory Cards have a primary key and separate photo/question-audio/answer-audio asset references; MEDIA_ASSETS is metadata for files in private Supabase Storage; open-ended reminiscence responses do not receive a correctness mark.

Android uses SQLite and app-private media storage. PWA uses IndexedDB, Service Worker and Cache API. Both require reliable local-first recording, a retryable/idempotent sync queue and a manual Sync Now action. Do not assume browser Background Sync is universally available.

Never expose the Supabase service-role key or weaken RLS. Never create fake metrics, dead buttons or claim untested functionality. Healthcare PDFs are factual activity summaries, not clinical assessments. Do not claim speech recognition unless it is implemented and tested.

Respect the assigned Git branch and file ownership. Do not modify shared database schema/contracts concurrently with another agent. Do not push or merge to `main` without project-owner approval. Before editing, inspect `git status` and preserve uncommitted work.

When finishing, report files changed, commands/tests actually run, outcomes, limitations, commit hash and any cross-client/schema impact.
