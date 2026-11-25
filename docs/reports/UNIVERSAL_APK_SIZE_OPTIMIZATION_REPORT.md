# KinCare Universal APK Size Optimization Report

**Branch:** `feature/phase5`  
**Flutter:** 3.47.9 / Dart 3.13.7  
**Android Gradle Plugin:** 9.1.0  
**Package:** `com.kincare.kincare_android`  
**Version:** `1.0.0` (version code 1)

## Result

The final universal release APK is **26,854,269 bytes** (26.854 MB / 25.610 MiB), below both the 40 MB stretch target and the 49,000,000-byte submission target. It retains `armeabi-v7a`, `arm64-v8a`, and `x86_64` and includes the current Memory Deck card persistence and synchronization source.

| Measure | Original baseline | Final release |
| --- | ---: | ---: |
| APK size | 59,271,221 bytes (59.271 MB / 56.525 MiB) | 26,854,269 bytes (26.854 MB / 25.610 MiB) |
| SHA-256 | `5B5D80D180DA7F969A3941F986A5F66D8D51BF0C735388AA8BCEDBD9718B60BD` | `7B3D3543117DC21805B2AFFA9F2DED48D45AE023706D3CFC0CCE1A0C8FB6B5EA` |
| Change | — | −32,416,952 bytes (−54.6926%) |

The final APK is at `android_app/build/app/outputs/flutter-apk/app-release.apk`.

## Baseline preservation

At task start, the existing output was measured at 59,271,221 bytes with the original SHA-256 above. A temporary copy was verified, but that temporary location did not persist across isolated command sessions. Before any source edit, the unchanged source was rebuilt as a universal APK and a durable pre-optimization copy was saved outside the build output at `D:\kincare-round3\_apk_artifacts\pre-optimization-universal.apk`.

That durable copy is also 59,271,221 bytes, with SHA-256 `F4F29C292B8AEFBBB1952C14FAE014F393CC6B731EAF595CED37CC62B75E95EF`. Its hash differs from the original output hash, so it is a regenerated pre-optimization baseline, not a byte-for-byte copy of the first APK. No application source had changed between those two builds.

## Size investigation

The original APK was inspected with Flutter's APK size analysis and Android's `apkanalyzer` CLI. Flutter rejects `--analyze-size` for a multi-ABI build, so its supported single-ABI analysis was run for `android-arm64`:

```powershell
flutter build apk --analyze-size --release --target-platform android-arm64 --dart-define-from-file=dart-defines.json --no-pub
```

Flutter reported a 19.9 MB arm64 APK analysis; its breakdown attributed about 19 MB to the arm64 native libraries, about 479 KB to DEX, about 133 KB to Flutter assets, and about 7 MB of decompressed Dart AOT symbol-accounted code. The original universal APK archive inspection showed:

| Original APK component | Bytes in APK entries |
| --- | ---: |
| arm64-v8a native libraries | 19,702,232 |
| armeabi-v7a native libraries | 17,331,736 |
| x86_64 native libraries | 21,195,032 |
| Android resources | 220,226 |
| DEX | 490,460 |
| Flutter assets | 135,916 |
| Other entries and metadata | 119,632 |

The three ABI copies of `libflutter.so`, `libapp.so`, `libdartjni.so`, and `libdatastore_shared_counter.so` total **58,229,000 bytes**, over 98% of the original APK. `libflutter.so` contributes 33,463,620 bytes and Dart AOT `libapp.so` contributes 24,414,552 bytes. The source asset directory contains only the small bundled cognitive-game JSON; user photographs and recordings are stored as app data, not packaged media. No large duplicate image, audio, or font assets were found. Flutter's release build already tree-shakes Material Icons from 1,645,184 to 6,932 bytes.

## Optimization applied

In `android_app/android/app/build.gradle.kts`, the Android Components API now enables `useLegacyPackaging` only for the `release` variant. This ZIP-compresses native `.so` libraries while retaining every ABI and library. The final APK contains all 12 native library entries, compressed to 25,926,202 bytes. The debug variant remains unchanged and packages its native libraries uncompressed.

Android extracts these compressed libraries during installation. This reduces the APK download/upload size but increases installed storage use compared with page-aligned, uncompressed libraries. Android documents this behavior and the trade-off in its [native library packaging guidance](https://developer.android.com/build/releases/agp-4-2-0-release-notes) and [16 KB page-size guidance](https://developer.android.com/guide/practices/page-sizes). All 12 final shared libraries were inspected with NDK 28.2 `llvm-readelf`; each ABI had a minimum ELF `LOAD` alignment of 16,384 bytes, and no `.debug_*` or `.zdebug_*` sections were present.

### Options evaluated but not applied

- **R8/resource shrinking:** release minification was not enabled. The existing DEX is 490,460 compressed bytes and Android resources are 220,226 bytes, while the native libraries dominate size. No project ProGuard rules existed. Because R8/resource shrinking can affect plugin classes or resources used through reflection and this task had no connected device for release runtime testing, the potential small extra reduction did not justify adding an unverified runtime risk after the target was already met.
- **Dependency removal:** no dependency was removed. Android plugins support existing recording, local storage, authentication, media, reports, and platform-channel functionality; the inspected native plugin libraries are a small fraction of the package.
- **Image/audio recompression:** no large bundled image or audio files exist to optimize. The existing `cognitive_games.json` remains bundled.
- **Debug symbols:** the native shared libraries already contain no ELF debug sections. No crash-symbol data was removed and Dart obfuscation was not enabled.
- **ABI splitting:** not used. This remains a single universal APK.

## Verification

| Check | Result |
| --- | --- |
| Targeted Memory Deck/SQLite tests: `flutter test test/memory_card_sync_test.dart test/offline_store_behavior_test.dart` | Passed, 14 tests |
| Full `flutter test` | Passed, 42 tests |
| `flutter analyze` | Exit code 1; 27 informational lint/deprecation notices, no errors reported |
| Debug APK build | Passed; 225,423,830 bytes; all three ABIs present and native libraries remain uncompressed |
| Universal release APK build | Passed; 26,854,269 bytes |
| Android APK Analyzer package/version | `com.kincare.kincare_android`, version `1.0.0`, code 1 |
| Release manifest INTERNET permission | Present |
| Release manifest `extractNativeLibs` | `true`, as required for compressed native libraries |
| APK signature | Verified with `apksigner`; one signer, APK Signature Scheme v2 valid |
| ZIP alignment check | `zipalign -c -P 16 4` exited 0 |
| ABI entries | `armeabi-v7a`, `arm64-v8a`, `x86_64`; 12 native libraries |
| Bundled cognitive game content | `assets/flutter_assets/assets/cognitive_games.json` present |
| Dart configuration | Build used `--dart-define-from-file=dart-defines.json`; both `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` names were present in the file. Values were not printed. |
| Physical-device runtime | Not tested; phone was disconnected |

The exact final release build command was:

```powershell
flutter build apk --release --target-platform android-arm,android-arm64,android-x64 --dart-define-from-file=dart-defines.json
```

The final APK timestamp was 2026-11-25 20:35:36. The APK was built after tests from the optimized source. Android reports a valid v2 signature; the existing project release build type still uses the debug signing configuration, so a separate production keystore was not introduced by this task.

Build output included non-fatal Flutter/Gradle warnings about restricted Java native access and the `flutter_tts` and `record_android` plugins applying Kotlin Gradle Plugin. They did not prevent either APK build.

## Files changed and project impact

- `android_app/android/app/build.gradle.kts` — release-only compressed native library packaging.
- `docs/reports/UNIVERSAL_APK_SIZE_OPTIMIZATION_REPORT.md` — this report.
- `_apk_artifacts/pre-optimization-universal.apk` — durable pre-optimization baseline copy, outside the build output.

No PWA, Flutter/Dart feature code, Supabase schema, RLS, authentication configuration, permissions, or dependencies were changed for this optimization. Existing uncommitted source changes were preserved. No commit or push was made. Physical installation and runtime behavior, including the installed-storage increase from library extraction, still require device testing.
