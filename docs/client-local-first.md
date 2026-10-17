# DAYMARK client: local-first task manager

Everything below is in `apps/client`. There is no backend dependency: the app works fully offline and never contacts a server.

> **Verification status.** This code was written in an environment with no Flutter SDK, so **`flutter analyze`, `flutter test`, the Drift code generation and every build have NOT been run.** The first thing to do is the commands in "First run" below and send back any errors. See "What has and has not been verified" at the end.

## First run (PowerShell, from the project folder)

Requires Flutter 3.38.1 or newer (Dart 3.10+); the new packages will not resolve on older SDKs.

```powershell
cd apps\client
flutter --version
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # creates lib\data\database\app_database.g.dart
flutter analyze
flutter test
flutter run -d chrome          # web
flutter run                    # Android device or emulator (see "Android setup" first)
```

`app_database.g.dart` is generated and must exist before the app compiles. Re-run `build_runner` whenever `app_database.dart` changes.

If `flutter pub get` reports a version conflict, paste the message back: `drift_dev` needs a recent `analyzer`, and which `build_runner` release fits depends on your exact Dart version.

## Features

* Create, view, edit, complete/uncomplete, reschedule and delete tasks, with priority (low/medium/high), optional due date and time, notes, recurrence and reminders.
* Five views with live counts: **Today**, **Upcoming**, **Overdue**, **Completed**, **All tasks**. Today shows completion progress.
* Responsive layout: sidebar from 840 px wide, bottom navigation below that.
* Light/dark theme with a header toggle (also in Settings, where "System" is available); the choice is saved.
* Sync-status dot in the header, next to the theme toggle (see below).

## Data model and rules

### Storage

SQLite through Drift (`lib/data/database/app_database.dart`), schema version **1**, with indexes on due date, status and update time. Three tables:

| Table | Holds |
|---|---|
| `tasks` | One row per task *definition*, including its recurrence rule, reminder and `updatedAt` (for future sync) |
| `occurrence_completions` | One row per **completed** occurrence of a repeating task (composite key: task + date) |
| `app_settings` | Theme and notification choice |

Dates are stored as `yyyy-MM-dd` local calendar dates, times as minutes since midnight, instants as epoch milliseconds. A due date therefore never shifts with time zones or daylight saving.

To change the schema: raise `AppDatabase.currentSchemaVersion` and add a numbered block to `onUpgrade` in `app_database.dart`. Never edit an old block.

### Recurrence

Occurrences are **computed from the rule, never stored**; only completions are stored. This is what guarantees that a restart or an edit cannot create duplicate occurrences, and that completing one date can only ever affect that date. An occurrence's identity is `<taskId>@<yyyy-MM-dd>`.

| Rule | Behaviour |
|---|---|
| One-time | A single occurrence on the due date (or none, if undated) |
| Daily | Every day from the start date |
| Weekly | The selected weekdays, every week, from the start date |
| Monthly | One chosen day each month, from the start date |

**Month-end rule.** A monthly rule for day 29, 30 or 31 runs on the **last day** of any shorter month. "Monthly on the 31st" gives Jan 31, Feb 28 (29 in leap years), Mar 31, Apr 30, ... Each month is computed from the rule, not from the previous occurrence, so there is no drift (it never becomes Mar 28). The form says this when day 29-31 is chosen.

Other recurrence behaviour:

* The task's **due date is the series start**. Nothing is generated before it.
* **Editing a repeating task changes the whole series** (title, time, rule, reminder). Completed history is kept even if the new rule no longer produces that date.
* Unfinished past occurrences are kept and shown as **Overdue**. To keep lists bounded, repeating occurrences are generated from 366 days back to 60 days ahead (`OccurrenceEngine`); unfinished occurrences older than 366 days stop being generated. One-time tasks are never dropped.
* There is no end date and no "every N days/weeks" interval.
* **Reschedule** (move to tomorrow / pick a date) is offered for one-time tasks only. For a repeating task, use Edit to change its start date, time or rule; moving a single occurrence is not supported.
* Deleting a repeating task deletes the whole series and its history, after confirmation.

### Overdue

An unfinished occurrence is overdue once its deadline has passed: the due *time* for a timed task, the *end of the due day* for a date-only task. A task with **no due date is never overdue**. A timed task due earlier today appears in both Today and Overdue.

### Reminders

A reminder is a date and a time. For a repeating task it keeps the same distance from every occurrence (a reminder set "1 day before at 09:00" fires 1 day before each one). Rescheduling a one-time task moves its reminder by the same amount. A task may have one reminder; multiple reminders per task are not supported.

## Notifications

Notifications use `flutter_local_notifications` 22.x. The user's choice is saved in Settings; permission is requested **only when the user turns notifications on** (the Settings switch, or "Turn on" inside the task form), never at startup.

After every change (create, edit, complete, reschedule, delete) and at start-up, the whole schedule is recomputed from the current tasks and *replaced*, using stable per-occurrence ids. Completed and deleted tasks drop out, rescheduled ones move, and nothing is duplicated. At most the 50 soonest reminders within the next 30 days are scheduled.

| Platform | How it works | Limits |
|---|---|---|
| **Android** | Scheduled with the operating system (`zonedSchedule`), so they fire when the app is closed | Uses an *inexact* alarm (no special exact-alarm permission), so Android may deliver a few minutes late. Some phone makers (Xiaomi, Huawei, ...) kill background work; the plugin cannot override that. Samsung has been reported to cap alarms at about 500. |
| **Chrome / web** | Browsers cannot schedule notifications, and the plugin does not support scheduling on the web. While the DAYMARK tab is open, an in-app timer shows the notification at the right time (and a message inside the app). | **Nothing is delivered if the tab or Chrome is closed.** Background tabs may throttle timers. The page must be served from `https` or `localhost`. The notification service worker may need one page reload before the first notification can show. If permission is blocked, the user must allow it in the browser's site settings. |

Settings states this limitation in the app. Delivery after closing Chrome is **not** implemented and is not claimed.

### Android setup (you must do this: the Android project files were not in the upload)

Edit your own `android/` files as described in the plugin's README (v22):

* `android/app/build.gradle(.kts)`: enable core library desugaring (`isCoreLibraryDesugaringEnabled = true` plus `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")`), Java 17 compatibility, `multiDexEnabled = true`, and `compileSdk = 36`. The plugin needs Android Gradle Plugin 8.11.1 or newer.
* `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`: `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>` and `<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>`. Inside `<application>`:
  ```xml
  <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
  <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
      <intent-filter>
          <action android:name="android.intent.action.BOOT_COMPLETED"/>
          <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
          <action android:name="android.intent.action.QUICKBOOT_POWERON" />
          <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
      </intent-filter>
  </receiver>
  ```
* The notification icon is the launcher icon (`@mipmap/ic_launcher`). A dedicated monochrome status-bar icon was not part of the supplied brand assets, so Android may draw the icon as a plain square in the status bar.

## Flutter Web database

The web build runs SQLite compiled to WebAssembly through `drift_flutter`. It needs two files in `web/`, both added:

| File | Source |
|---|---|
| `web/sqlite3.wasm` | `sqlite3-3.7.1` release of simolus3/sqlite3.dart |
| `web/drift_worker.js` | `drift-2.35.2` release of simolus3/drift |

**`drift`, `drift_flutter` and `sqlite3` are pinned to exact versions in `pubspec.yaml` because these two files must match them exactly.** To upgrade, change the pins and download the files from the matching GitHub release assets (`https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-<version>/sqlite3.wasm` and `https://github.com/simolus3/drift/releases/download/drift-<version>/drift_worker.js`).

The browser chooses where data lives (OPFS or IndexedDB) and Drift reports the choice; Settings > Storage shows it. If the browser can only offer memory (for example some private-browsing modes), data would be lost on refresh, so the app shows a clear red warning on every list instead of failing silently. Data is per browser profile and per origin (`localhost:port` and a deployed URL are separate databases).

Platform limits to expect:

* Persistence across refreshes depends on the browser; it has not been tested in a browser here.
* Two tabs open at once share one database, but a change in one tab appears in the other only after that tab reloads or changes something.
* Clearing site data deletes the tasks. There is no export or backup in this release.

## Sync indicator

`lib/services/sync_status.dart` holds a small state machine, `SyncStateMachine`, and the header widget `SyncStatusIndicator` reads it. There is **no backend and no networking code**: nothing in the app changes this state to anything but Local-only.

| State | Dot | When |
|---|---|---|
| Local only | grey | No backend configured. **This is what the app shows in this release.** |
| Syncing | yellow | A sync request is in progress |
| Offline | red | Backend unreachable, last sync failed, local changes waiting, or nothing confirmed yet |
| Synced | green | Only when the backend has **acknowledged every** local change |

A future sync engine drives it with `configureBackend`, `syncStarted`, `syncSucceeded(acknowledgedChanges: n)`, `syncFailed(error)` and `connectivityChanged(online: ...)`. Every local change already calls `recordLocalChange()`, so a pending-change count is ready. The dot has a tooltip and a screen-reader label, and a text label on wide screens.

## Layout of the code

```
lib/models/     task, recurrence, occurrence, views, validation, date helpers (pure Dart)
lib/data/       Drift database, task and settings repositories
lib/services/   occurrence engine, reminder planner/service, notification gateway, sync status
lib/app/        app root and controller (AppController, AppScope)
lib/features/   tasks (home, list, tile, form, details), settings
lib/shared/     reusable widgets (logo, sync indicator, theme toggle, empty state)
test/           unit, repository, controller and widget tests
```

## What has and has not been verified

**Done in the build environment:**

* Every Dart file was parsed with a Dart syntax parser (no syntax errors).
* The calendar logic (month-end clamping, leap years, weekday lists, view membership and ordering, overdue boundaries, reminder offsets, sync-state transitions, the planner) was cross-checked by running the *same expectations* as the tests against an independent Python re-implementation. All agreed. This checks the intended behaviour; it does not prove the Dart compiles.
* Package APIs (Drift 2.35, `drift_flutter` 0.3, `flutter_local_notifications` 22.3) were read from the actual released sources, and the web assets were downloaded from the matching releases.

**Not done (no Flutter SDK available, and pub.dev and Google's SDK host are blocked):**

* `dart run build_runner build`, `flutter pub get`, `flutter analyze`, `flutter test`
* Any run in Chrome or on Android; persistence after a real browser refresh; actual notification delivery
* Android and web release builds

## Known limitations

* No backend sync, backup or export.
* One reminder per task; no snooze; no quiet hours.
* Browser notifications work only while the tab is open (see above).
* Android reminders are inexact and need the manual Gradle/manifest setup above.
* No keyboard shortcuts or collapsible sidebar.
* Task search, filters, projects, subtasks, the focus timer and progress reports are out of scope for this phase.
