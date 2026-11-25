# KinCare Android Authentication and Network Investigation

**Updated:** 2026-11-25  
**Branch:** `feature/phase5`  
**Scope:** Android manifest, release Supabase configuration, safe network diagnostics, and release APK verification.

## Findings and changes

The earlier Brave responses show that the phone browser reached the Supabase gateway at the time of those requests. The auth endpoint's missing-API-key response is expected for a request without an `apikey` header; it is not evidence of a Supabase outage. Flutter's `SocketException: Failed host lookup` occurs before an HTTP request can reach Supabase and indicates a DNS lookup failure for that attempt.

The investigation found two independent release-build problems:

1. The main Android manifest did not declare `android.permission.INTERNET`. Debug inherited this permission from its variant manifest, but release did not. The main manifest now declares it outside `<application>`, preserving all existing permissions and app settings.
2. The prior workspace APK had been built without `dart-defines.json`. The configured local file exists and supplies `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. The URL host matches the reported lookup failure. The publishable key value was neither logged nor included here. The file remains local and ignored by Git.

The app still uses Supabase's default HTTP client and Android's normal hostname resolution. No custom DNS resolver, hardcoded IP address, proxy, or authentication architecture change was introduced.

Safe diagnostics were added around Supabase initialization, authentication operations, and the existing internet reachability probe. They distinguish DNS lookup failures, connection failures, timeouts, HTTP/API responses, authentication exceptions, missing configuration, and unexpected errors. Diagnostic lines contain only a fixed operation name, sanitized host, category, exception type, and safe numeric status/OS code where available. They do not contain raw exception text, request bodies, phone numbers, OTPs, passwords, tokens, or API keys.

## Files changed for this fix

- `android_app/android/app/src/main/AndroidManifest.xml` — added the Internet permission to the main manifest.
- `android_app/lib/auth_network_diagnostics.dart` — added safe failure classification and logging.
- `android_app/lib/main.dart` — added safe Supabase configuration checks and authentication failure diagnostics; the existing local Dart defines remain the configuration source.
- `android_app/lib/offline_sync.dart` — added safe diagnostics to the existing reachability probe and sync failure path without changing network configuration.
- `android_app/test/auth_network_diagnostics_test.dart` — added tests for failure classification and secret-free log output.
- `README.md` — documented the universal release build command and output location.
- `docs/reports/ANDROID_AUTH_NETWORK_INVESTIGATION.md` — recorded findings and verification.

Other Phase 6 modifications already present in the working tree were preserved. No Dart defines file was added to source control.

## Verification results

### Tests and analysis

- `flutter test` — **passed: all 38 tests**.
- `flutter analyze` — **no errors; 27 informational lint/deprecation notices**, exit code 1 because the analyzer reports informational issues as findings. They are in existing screens and are unrelated to the new diagnostics.
- The new diagnostics tests cover DNS failures (including wrapped Supabase fetch errors), connection failures, timeouts, API responses, authentication exceptions, missing configuration, and exclusion of supplied sensitive strings from logs.

### Merged manifests

Inspected the generated merged manifests:

- Debug: `android_app/build/app/intermediates/merged_manifests/debug/processDebugManifest/AndroidManifest.xml` — `android.permission.INTERNET` present.
- Release: `android_app/build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml` — `android.permission.INTERNET` present.

### Release APK

Built from `android_app/` using the local ignored Dart defines file:

```powershell
flutter build apk --release --target-platform android-arm,android-arm64,android-x64 --dart-define-from-file=dart-defines.json
```

- Build result: **success**.
- APK: `android_app/build/app/outputs/flutter-apk/app-release.apk`
- Size: **59,271,221 bytes (56.5 MiB)**.
- SHA-256: `29DD5BD5E0900CD9DD7C968044C69B457ED2E2A451E786F08F829A6978E96350`
- ABI libraries included: `armeabi-v7a`, `arm64-v8a`, and `x86_64`; this is the requested universal APK.
- A binary check of the ARM64 Flutter app library confirmed the configured URL and publishable key are embedded. Only true/false results were recorded; the key itself was not displayed.

## Remaining verification

No physical Android device was available through `adb` in this environment, so no real OTP request was made and no installed APK hash was compared. **Login is not claimed fixed.** A physical-device test still needs to install this exact APK, verify the build hash, perform a real Supabase OTP request, and confirm the resulting safe diagnostic category if networking fails.
