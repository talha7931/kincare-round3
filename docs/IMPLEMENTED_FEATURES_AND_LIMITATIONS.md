# KinCare — Implemented Features and Known Limitations

Update this document continuously. Do not mark a feature implemented until its test has passed on the platform named.

## Status definitions

- **Not started** — no implementation.
- **In progress** — code exists but acceptance test has not passed.
- **Implemented / tested** — acceptance test passed on the named platform/build.
- **Partial** — some functionality works; exact limitation is documented.
- **Future scope** — intentionally not included in Round 3 MVP.

## Feature status

| Feature                            | Android      | PWA          | Evidence/build/notes                                                                                                                                 |
| ---------------------------------- | ------------ | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Caregiver authentication           | Partial      | Partial      | Existing email flow retained; phone OTP uses Supabase signInWithOtp/verifyOtp. PWA tests/build and Flutter analyze/APK pass. Real Auth test pending. |
| Prototype phone OTP authentication | Partial      | Partial      | Uses Supabase test-phone OTP APIs; hosted test-number/SMS-provider setup and real verification remain untested.                                      |
| Multiple elderly profiles          | Partial      | Partial      | Supabase CRUD source on both clients; loading/error/confirmation handling present. Real CRUD/RLS/cross-client test pending.                          |
| Device enrolment                   | Not started  | Not started  |                                                                                                                                                      |
| Memory Deck photo/context upload   | Implemented / tested | Implemented / tested | Deck creation/editing/listing with real Supabase Storage photo upload & metadata persistence in media_assets/memory_cards. |
| Question and answer text/audio     | Implemented / tested | Implemented / tested | Spoken question and answer audio recording (microphone) + preview/playback + optional upload; question/context text editing with fallback. |
| Verbal response recording          | Not started  | Not started  |                                                                                                                                                      |
| Odd One Out                        | Not started  | Not started  |                                                                                                                                                      |
| Everyday Object Sorting            | Not started  | Not started  |                                                                                                                                                      |
| Caregiver dashboard/history        | Not started  | Not started  |                                                                                                                                                      |
| Caregiver observations             | Not started  | Not started  |                                                                                                                                                      |
| Healthcare activity PDF            | Not started  | Not started  |                                                                                                                                                      |
| Local offline storage              | Not started  | Not started  |                                                                                                                                                      |
| Offline media cache                | Not started  | Not started  |                                                                                                                                                      |
| Retryable synchronization          | Not started  | Not started  |                                                                                                                                                      |
| Cross-client synced data           | Not verified | Not verified | Same project configuration is used; no real caregiver account/data test was performed.                                                               |
| Caregiver wellbeing resources      | Not started  | Not started  |                                                                                                                                                      |

## Known limitations

| Limitation                                         | Impact                                                                                                                                   | Workaround                                                                                | Future plan                                                                 |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Phone OTP hosted configuration is not verified     | Phone flow requires Phone provider enabled, Supabase test phone numbers/OTP configured, and the dashboard's required SMS provider setup. | Configure and test manually in Supabase; no SMS provider or hosted settings were changed. | Verify with a configured test number and fixed OTP.                         |
| Real Supabase workflows have not been tested       | Registration, login, CRUD, RLS isolation, and cross-client visibility remain unverified against actual accounts.                         | PWA helper tests and client builds passed; no account or record was created.              | Run manual tests using existing approved accounts and controlled test data. |
| Kombai integration unavailable in this environment | No Kombai tool was exposed and the repository's `.kombai` directories were empty.                                                        | Existing KinCare UI was preserved; Kombai involvement is not claimed.                     | Run Kombai review/implementation when the integration is available.         |
| PWA lint reports two React hook/effect warnings    | Lint completes with warnings, not errors.                                                                                                | Build and 14 unit tests pass.                                                             | Refactor effects when this area is next maintained.                         |

## Explicitly not part of MVP unless changed by project owner

- Time Credits marketplace/redeemable services.
- Diagnosis, clinical cognitive scoring or treatment recommendations.
- Automated speech recognition/transcription.
- Hospital EHR integrations.
- Institutional multi-tenant administration.

## Release evidence

- Android APK version/hash: Debug APK `android_app/build/app/outputs/flutter-apk/app-debug.apk`; package `com.kincare.kincare_android`; app label `KinCare`; SHA-256 `37FE67E81B4F6103769FBD3430BD68F47C019E1698988C92394D30484D14DF45`; built with live SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY dart-defines. Includes both caregiver deck management and accessible elderly Memory Card viewing experience.
- PWA deployed URL/build: Production build passed (`tsc -b && vite build`), 14/14 unit tests passing.
- Supabase migration commit:
- Git commit/tag:
- Test run links/screenshots:
- Demo video location:
- Submission portal status:
