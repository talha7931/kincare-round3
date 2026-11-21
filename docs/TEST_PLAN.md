# KinCare — Round 3 Test Plan

Record test date, platform/device/browser, build/commit, tester, steps, expected result, actual result and pass/fail for every test.

## A. Shared account and profiles

- [ ] Caregiver can register, log in, restore session and log out.
- [ ] Caregiver can create, edit and select multiple elderly profiles.
- [ ] A second caregiver cannot read or modify the first caregiver's profiles.
- [ ] An enrolled device belongs to the caregiver and can serve that caregiver's different profiles.
- [ ] A session cannot be created for a profile owned by another caregiver.

## B. Memory Decks

- [ ] Caregiver can create deck for selected profile.
- [ ] Caregiver can upload photograph and add context.
- [ ] Caregiver can enter question and answer/context text.
- [ ] Caregiver can add/record question and answer audio, or the UI clearly explains fallback.
- [ ] Elderly user can play photo/question/answer content.
- [ ] Elderly verbal response can be recorded when permission is granted.
- [ ] Denying microphone permission produces a usable text/skip fallback.
- [ ] Memory Deck responses are not falsely marked wrong.

## C. Cognitive activities

- [ ] Odd One Out starts an enrolled-device session for the selected profile and the `odd_one_out` activity type.
- [ ] Odd One Out records correct and incorrect selections with round index, selected item, expected item, timestamp and nullable correctness.
- [ ] Odd One Out instruction audio can be replayed; unavailable speech has a readable instruction fallback.
- [ ] Odd One Out advances through each round and completes the session only after responses are saved.
- [ ] Everyday Object Sorting starts an enrolled-device session for the selected profile and the `everyday_object_sorting` activity type.
- [ ] Everyday Object Sorting supports tap-to-select, tap-to-place and changing a placement before submit.
- [ ] Everyday Object Sorting records one final response per object with selected/expected categories and correctness.
- [ ] Both games can be exited as abandoned and completed sessions show as completed.
- [ ] Caregiver activity history shows profile, activity, date, status and saved response summaries.
- [ ] Touch targets, text and audio instructions are usable on target devices.
- [ ] Sessions and responses are associated with correct profile and device.

## D. Dashboard and PDF report

- [ ] Dashboard aggregates actual stored sessions/responses.
- [ ] Empty state is clear when no sessions exist.
- [ ] Date range/profile filters work, if implemented.
- [ ] Caregiver can add observations.
- [ ] PDF includes profile, caregiver, period, sessions, activity breakdown, available response summaries and caregiver notes.
- [ ] PDF includes non-clinical disclaimer and sync/data coverage note.
- [ ] No diagnosis, clinical cognitive score or unvalidated improvement claim appears.

## E. Offline and sync — run separately on Android and PWA

- [ ] Initial online login and content caching/download works.
- [ ] App can relaunch/load offline after required content is cached.
- [ ] Offline activity session and responses are stored locally.
- [ ] Records survive app/browser restart while still offline.
- [ ] Sync Now sends queued records after reconnecting.
- [ ] Retrying sync does not create duplicates.
- [ ] Failed upload remains visible and retryable.
- [ ] Media and structured records are linked correctly.
- [ ] Synced activity appears in the other client after refresh.

## F. Security and release

- [ ] RLS prevents cross-caregiver access to profiles, decks, sessions, responses and media.
- [ ] Private Storage policies enforce ownership.
- [ ] No service-role key/database password in source, APK or PWA bundle.
- [ ] `.env` files are not committed.
- [ ] Android release APK installs and launches on a real phone.
- [ ] PWA is served over HTTPS and installation works in the target browser.
- [ ] README instructions are followed from a fresh checkout.
