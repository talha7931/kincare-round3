# KinCare — Shared Instructions for All Coding Agents

Read `docs/KINCARE_ROUND3_MASTER_SPEC.md` before making changes. It is the product and architecture source of truth.

## Mission
Build the Round 3 KinCare MVP: Flutter Android + React/TypeScript PWA, both offering the same core caregiver and elderly journeys through one Supabase backend. Do not split the platforms into different products.

## Before changing code
1. Inspect the existing repository, status, branches, README and tests. Do not assume the project is empty after repository connection.
2. Read the master spec and relevant docs.
3. Identify the exact files you intend to change and the acceptance tests for the task.
4. If a required decision conflicts with the master spec, stop and ask the project owner; do not silently redesign it.

## Collaboration and Git
- Never work directly on `main`.
- Work only on the branch assigned to you. Do not switch branches or rewrite another agent's commits.
- Do not run destructive Git commands (`reset --hard`, force push, deleting branches/worktrees) unless the project owner explicitly instructs you.
- Do not overwrite uncommitted work. Check `git status` before edits and before commits.
- Keep changes narrow and commit in small, descriptive commits.
- Do not edit shared schema/contracts concurrently with another agent. One designated backend/schema owner maintains Supabase migrations and data contracts.
- If a change affects both clients, update the contract/spec first and tell the other platform owner what changed.
- Do not merge or push to `main` without the project owner's approval.

## Architecture invariants
- One Supabase project and one logical schema for both clients.
- Caregivers authenticate; elderly profiles do not have individual login accounts in this MVP.
- One caregiver can own multiple elderly profiles and multiple devices.
- A device is linked to a caregiver, not permanently to one elderly profile.
- Every activity session references both `elderly_profile_id` and `device_id`.
- Memory Decks include `created_by_caregiver_id`.
- Memory Cards have their own `id`, `deck_id`, `photo_asset_id`, optional question/answer audio asset references, question text and answer context.
- MEDIA_ASSETS stores metadata; file bytes live in private Supabase Storage.
- Activity response correctness is nullable; open-ended Memory Deck responses are not marked wrong.
- Both apps implement the same core user journeys; only platform-specific UI and local persistence differ.
- Android local data: SQLite + app-private media files.
- PWA local data: IndexedDB + Service Worker/Cache API + browser-managed media cache.

## Security
- Never place Supabase service-role keys, database passwords or private secrets in client code, source control, APKs or web bundles.
- Enforce ownership through Supabase RLS and private Storage policies; client-side checks alone are insufficient.
- Do not weaken RLS to make a demo work.
- Do not log access tokens, passwords, private media URLs or sensitive user data.
- Use synthetic/demo data for tests and demonstrations.

## Engineering rules
- Prefer small, testable, maintainable implementations over speculative abstractions.
- Reuse established dependencies and patterns already in the repo; don't add libraries without a clear need.
- Do not create fake dashboards, hard-coded live metrics, dead buttons or placeholder actions presented as working features.
- Never claim offline support merely because the app shell loads. Verify local records persist and sync exactly once after reconnecting.
- Activity sessions/responses are append-only for the MVP; do not silently overwrite history.
- Make sync operations idempotent and safe to retry.
- Handle denied microphone permission and unavailable audio with clear fallbacks.
- Doctor-facing reports are factual activity summaries, not clinical assessments or diagnostic outputs.
- Do not claim speech-to-text, AI-generated questions, clinical scoring or disease improvement unless implemented, tested and approved.

## Required handoff in every task response
Report:
1. What was changed.
2. Files changed.
3. Commands/tests run and their actual results.
4. Known limitations or failures.
5. Commit hash, if committed.
6. Any contract/schema impact and which other agent must be notified.

Do not state a test passed unless you ran it and saw it pass.
