# KinCare
### Offline-First Cognitive Stimulation and Caregiver Support Platform

KinCare is an offline-first application designed to support older adults through personalised cognitive activities and help caregivers provide meaningful engagement.

The platform allows caregivers to create memory decks using familiar photographs and descriptions. Older adults can use these decks and interactive activities to stimulate memory, recognition, and everyday thinking skills.

KinCare is designed to remain useful even when internet connectivity is unavailable. Activities and progress can be stored locally and synchronised with the cloud when a connection becomes available.

---

## The Problem

Older adults experiencing memory and cognitive difficulties may benefit from regular, familiar, and engaging activities. However, caregivers often face challenges in creating personalised activities and maintaining consistent engagement.

Internet connectivity can also be unreliable, limiting access to applications that depend entirely on cloud services.

KinCare addresses these challenges through personalised memory activities, simple interactive games, and offline-first functionality.

## Key Features

### 1. Personalised Memory Decks
- Caregivers can create memory decks using photographs and descriptions.
- Familiar images help provide context for memory-based activities.
- Decks and cards are available for offline use after being stored locally.

### 2. Cognitive Activities
- **Odd One Out:** Identify the item that does not belong in a group.
- **Everyday Object Sorting:** Sort familiar objects into appropriate categories.
- Interactive activities designed around recognition, attention, and basic reasoning.

### 3. Offline-First Functionality
- Local data storage using SQLite.
- Cached memory decks and activity data.
- Offline actions are recorded locally.
- A synchronisation queue processes pending changes when connectivity returns.
- Manual and automatic synchronisation support.

### 4. Caregiver Support
- Caregiver authentication.
- Memory deck and activity management.
- Activity history and engagement reporting.
- Local activity records that can be synchronised with the cloud.

### 5. Accessible Interaction
- Simple interfaces designed for older adults.
- Spoken prompts and multilingual support, including English, Hindi, and Marathi.

---

## Technology Stack

| Component | Technology |
|---|---|
| Android application | Flutter, Dart |
| Local database | SQLite (sqflite) |
| Cloud backend | Supabase |
| Authentication | Supabase Auth |
| Cloud database | Supabase PostgreSQL |
| Cloud media storage | Supabase Storage |
| Offline synchronisation | Local sync queue and Sync Manager |
| Version control | Git and GitHub |

## How Offline Synchronisation Works

KinCare follows an offline-first approach. The application does not require a continuous internet connection for its locally available activities.

1. **Local access:** The application loads cached data from SQLite.
2. **User activity:** New actions and changes are stored locally.
3. **Pending synchronisation:** Changes are added to a local synchronisation queue.
4. **Connectivity restored:** The Sync Manager detects an available connection and processes pending operations.
5. **Cloud update:** Data is synchronised with Supabase.
6. **Updated local state:** The application refreshes its local data while retaining access to offline content.

This approach helps maintain continuity when connectivity is intermittent.

## Project Structure

```text
kincare-round3/
│
├── android_app/
│   ├── android/
│   ├── lib/
│   │   ├── main.dart
│   │   ├── memory_decks_screen.dart
│   │   ├── elderly_memory_screen.dart
│   │   ├── cognitive_games_screen.dart
│   │   ├── offline_store.dart
│   │   ├── offline_sync.dart
│   │   └── ...
│   │
│   ├── test/
│   ├── pubspec.yaml
│   └── ...
│
├── docs/
│   └── reports/
│
└── README.md
```

## Getting Started

### Prerequisites
- Flutter SDK
- Dart SDK
- Android Studio or Android SDK
- A Supabase project with the required database and storage configuration

### Run Locally

Clone the repository:

```bash
git clone https://github.com/talha7931/kincare-round3.git
```

Navigate to the Android application:

```bash
cd kincare-round3/android_app
```

Install dependencies:

```bash
flutter pub get
```

Configure the required Supabase credentials using the project's expected local configuration. Do not commit private keys or credentials to GitHub.

Run the application:

```bash
flutter run
```

## Testing

The project includes automated tests covering important application behaviour, including:

- Offline database operations.
- Memory card and deck synchronisation.
- Cognitive game functionality.
- Authentication and network diagnostics.
- Offline data handling.

## Current Limitations

- Cloud synchronisation requires an internet connection.
- Previously cached content is available offline; new cloud content requires connectivity to retrieve.
- The current implementation is a prototype and has not been clinically validated.
- Additional physical-device testing and broader accessibility evaluation are needed.

## Future Roadmap

The following improvements are planned for future development:

- **Time Credits Module:** Introduce a time-credit system to recognise and encourage caregiver participation and support.
- **Expanded Cognitive Activities:** Add more personalised games and memory exercises.
- **Caregiver Wellbeing:** Provide guidance and resources to support caregivers.
- **Improved Accessibility:** Expand language options, voice interaction, and accessibility settings.
- **Enhanced Synchronisation:** Further improve conflict handling, reliability, and data recovery.
- **Further Testing:** Conduct broader usability testing with caregivers and older adults.

## Demo and Project Resources

- **GitHub Repository:** https://github.com/talha7931/kincare-round3
- **Prototype / APK:** [Add Google Drive link]
- **Prototype Demonstration:** [Add video link]
- **Project Explanation Video:** [Add video link]
- **Technical Documentation:** [Add documentation link]

## Disclaimer

KinCare is a cognitive stimulation and caregiver-support prototype. It is not a medical device and is not intended to diagnose, treat, or replace professional medical care.

---

**KinCare — Making familiar moments meaningful through technology.**
