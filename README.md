# KinCare — Care Beyond Connectivity

Round 3 prototype repository for PRASUNEX Innovathon 2026.

## Applications

- `android_app/` — Flutter/Dart Android application.
- `pwa/` — React/TypeScript installable Progressive Web App.
- `supabase/` — shared Supabase migrations, RLS policies and safe demo seed data.
- `docs/` — product specification, contracts, offline strategy, testing and submission evidence.

Both applications must support caregiver and elderly journeys and use the same Supabase backend. Read `AGENTS.md` and `docs/KINCARE_ROUND3_MASTER_SPEC.md` before making changes.

## First-time setup

### Supabase

Apply the ordered SQL migrations in `supabase/migrations/` to the project through the Supabase SQL editor or a linked Supabase CLI. No service-role key is required for application configuration.

### PWA

```powershell
cd pwa
npm install
npm run dev
```

Local PWA credentials are in the ignored `pwa/.env.local`. Copy `pwa/.env.example` to `.env.local` for another checkout.

### Flutter Android

Flutter must be installed and on `PATH`.

```powershell
cd android_app
flutter pub get
flutter analyze
flutter run --dart-define-from-file=dart-defines.json
flutter build apk --debug --dart-define-from-file=dart-defines.json
```

Copy `dart-defines.example.json` to `dart-defines.json`, add only the public URL and publishable key, and keep `dart-defines.json` untracked.

The debug APK is written to `android_app/build/app/outputs/flutter-apk/app-debug.apk`. Transfer it to an Android phone (USB file transfer or an approved private file share), open it from Downloads, allow installation from that source if Android prompts, and install. Test email sign-in, caregiver profile CRUD, sign-out/session restoration, and the caregiver/elderly mode switch. No physical-device install test has been recorded yet.

### Prototype phone authentication

Phone auth calls Supabase Auth's real SMS OTP endpoints; it does not generate or verify codes locally. Before testing, configure Supabase Auth Phone, add test phone number/fixed OTP pairs in the Supabase Dashboard, and complete any SMS-provider configuration Supabase requires. Test phone numbers do not send SMS, but the hosted provider requirement still applies. No phone numbers, OTPs, or provider credentials are stored in client source, and no hosted Auth settings were changed during implementation.

## Project status

Phase 1 schema/RLS and PWA/Flutter source scaffolds are in progress. A feature is not complete until its real-project acceptance test passes and its status is recorded in `docs/IMPLEMENTED_FEATURES_AND_LIMITATIONS.md`.
