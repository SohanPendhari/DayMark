import 'dart:io';

import 'package:daymark/app/app_controller.dart';
import 'package:daymark/data/database/app_database.dart';
import 'package:daymark/models/date_utils.dart';
import 'package:daymark/models/recurrence.dart';
import 'package:daymark/models/task_item.dart';
import 'package:daymark/models/task_views.dart';
import 'package:daymark/services/notification_gateway.dart';
import 'package:daymark/services/sync_status.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../support/test_app.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppController controller;
  late DateTime now;

  setUp(() async {
    now = kNow;
    controller = await makeController(clock: () => now);
  });

  tearDown(() => controller.dispose());

  TaskItem task({String id = 'a', String title = 'Task', DateTime? due, int? minutes, Recurrence rule = const Recurrence.none()}) =>
      makeTask(id: id, title: title, due: due, minutes: minutes, recurrence: rule);

  test('starts loaded, empty, and Local only (grey)', () {
    expect(controller.loading, isFalse);
    expect(controller.initError, isNull);
    expect(controller.views.all, isEmpty);
    expect(controller.sync.status, SyncStatus.localOnly);
  });

  test('an empty or blank title is refused and nothing is saved', () async {
    expect(await controller.saveTask(task(title: '')), contains('title'));
    expect(await controller.saveTask(task(title: '   ')), contains('title'));
    expect(controller.taskList, isEmpty);
  });

  test('invalid dates are refused', () async {
    expect(await controller.saveTask(task(minutes: 600)), isNotNull); // time without a date
    expect(await controller.saveTask(task(due: DateTime(1990, 1, 1))), isNotNull);
    expect(await controller.saveTask(task(due: DateTime(2026, 3, 10), rule: Recurrence.weekly(<int>{}))), isNotNull);
    expect(controller.taskList, isEmpty);
  });

  test('creating a task shows it in Today and All, and trims the title', () async {
    expect(await controller.saveTask(task(title: '  Buy milk  ', due: DateTime(2026, 3, 10))), isNull);
    expect(controller.views.today.single.task.title, 'Buy milk');
    expect(controller.views.all.length, 1);
    expect(controller.views.countFor(TaskTab.today), 1);
  });

  test('quickAdd creates a task due today', () async {
    expect(await controller.quickAdd('Call Sam'), isNull);
    expect(controller.views.today.single.task.title, 'Call Sam');
    expect(controller.views.today.single.date, DateTime(2026, 3, 10));
    expect(await controller.quickAdd('  '), isNotNull);
  });

  test('editing a task keeps its identity and bumps updatedAt', () async {
    await controller.saveTask(task(title: 'Old', due: DateTime(2026, 3, 10)));
    final before = controller.taskList.single;
    now = kNow.add(const Duration(minutes: 30));
    await controller.saveTask(before.copyWith(title: 'New', dueMinutes: 15 * 60));
    expect(controller.taskList.length, 1);
    final after = controller.taskList.single;
    expect(after.id, 'a');
    expect(after.title, 'New');
    expect(after.dueMinutes, 900);
    expect(after.updatedAt.isAfter(before.updatedAt), isTrue);
  });

  test('completing and un-completing a one-time task', () async {
    await controller.saveTask(task(due: DateTime(2026, 3, 10)));
    await controller.setCompleted(controller.views.today.single, true);
    expect(controller.views.completed.length, 1);
    expect(controller.views.todayProgress, 1.0);
    expect(controller.taskList.single.status, TaskStatus.completed);
    await controller.setCompleted(controller.views.completed.single, false);
    expect(controller.views.completed, isEmpty);
    expect(controller.views.todayProgress, 0.0);
    expect(controller.taskList.single.completedAt, isNull);
  });

  test('completing one occurrence of a repeating task leaves the others alone', () async {
    await controller.saveTask(task(due: DateTime(2026, 3, 8), rule: const Recurrence.daily()));
    final todayOccurrence = controller.views.today.single;
    await controller.setCompleted(todayOccurrence, true);

    expect(controller.views.completed.length, 1);
    expect(controller.views.completed.single.date, DateTime(2026, 3, 10));
    expect(controller.views.upcoming.every((o) => !o.isCompleted), isTrue);
    // 8 and 9 March stay unfinished and overdue.
    expect(controller.views.overdue.map((o) => formatDate(o.date!)), <String>['2026-03-08', '2026-03-09']);

    // Completing the same occurrence again changes nothing; reopening restores it.
    await controller.setCompleted(todayOccurrence, true);
    expect(controller.views.completed.length, 1);
    await controller.setCompleted(controller.views.completed.single, false);
    expect(controller.views.completed, isEmpty);
    expect(controller.views.overdue.length, 2);
  });

  test('editing a repeating task does not duplicate occurrences or lose history', () async {
    await controller.saveTask(task(due: DateTime(2026, 3, 8), rule: const Recurrence.daily()));
    await controller.setCompleted(controller.views.today.single, true);
    final keysBefore = controller.occurrences.map((o) => o.key).toSet();
    await controller.saveTask(controller.taskList.single.copyWith(title: 'Renamed'));
    final keysAfter = controller.occurrences.map((o) => o.key).toList();
    expect(keysAfter.toSet().length, keysAfter.length); // no duplicates
    expect(keysAfter.toSet(), keysBefore);
    expect(controller.views.completed.length, 1);
  });

  test('deleting a repeating task removes its history', () async {
    await controller.saveTask(task(due: DateTime(2026, 3, 8), rule: const Recurrence.daily()));
    await controller.setCompleted(controller.views.today.single, true);
    expect(await controller.deleteTask('a'), isNull);
    expect(controller.taskList, isEmpty);
    expect(controller.views.completed, isEmpty);
    expect(controller.occurrences, isEmpty);
  });

  test('rescheduling moves the task and keeps the reminder distance', () async {
    await controller.saveTask(makeTask(
      id: 'a', due: DateTime(2026, 3, 10), minutes: 18 * 60, reminder: true,
      reminderDate: DateTime(2026, 3, 10), reminderMinutes: 15 * 60,
    ));
    expect(await controller.reschedule(controller.taskList.single, DateTime(2026, 3, 14), 18 * 60), isNull);
    final moved = controller.taskList.single;
    expect(moved.dueDate, DateTime(2026, 3, 14));
    expect(moved.reminderDate, DateTime(2026, 3, 14));
    expect(controller.views.today, isEmpty);
    expect(controller.views.upcoming.single.date, DateTime(2026, 3, 14));
  });

  test('a task becomes overdue as time passes, without any user action', () async {
    await controller.saveTask(task(due: DateTime(2026, 3, 10), minutes: 11 * 60));
    expect(controller.views.overdue, isEmpty);
    now = DateTime(2026, 3, 10, 11, 30);
    controller.refreshTime();
    expect(controller.views.overdue.length, 1);
    now = DateTime(2026, 3, 11, 0, 5);
    controller.refreshTime();
    expect(controller.views.today, isEmpty); // the day rolled over
    expect(controller.views.overdue.length, 1);
  });

  test('every change is recorded for the future sync, yet the indicator stays Local only', () async {
    await controller.quickAdd('One');
    await controller.quickAdd('Two');
    expect(controller.sync.snapshot.pendingChanges, 2);
    expect(controller.sync.status, SyncStatus.localOnly);
  });

  test('a notification tap focuses the matching occurrence', () async {
    await controller.saveTask(task(due: DateTime(2026, 3, 12)));
    controller.handleNotificationTap('a@2026-03-12');
    expect(controller.focusedOccurrence.value?.task.id, 'a');
    controller.focusedOccurrence.value = null;
    controller.handleNotificationTap('missing@2026-01-01');
    expect(controller.focusedOccurrence.value, isNull);
  });

  group('theme', () {
    test('toggle flips light and dark', () async {
      expect(controller.themeMode.value, ThemeMode.light);
      await controller.toggleTheme(Brightness.light);
      expect(controller.themeMode.value, ThemeMode.dark);
      await controller.toggleTheme(Brightness.dark);
      expect(controller.themeMode.value, ThemeMode.light);
    });
  });

  group('persistence across a restart', () {
    test('tasks, history, theme and the notification choice come back', () async {
      final dir = Directory.systemTemp.createTempSync('daymark_ctl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/daymark.sqlite');

      final gateway = FakeNotificationGateway();
      final first = await makeController(database: AppDatabase(NativeDatabase(file)), gateway: gateway);
      await first.saveTask(task(id: 'p', title: 'Persistent', due: DateTime(2026, 3, 8), rule: const Recurrence.daily()));
      await first.setCompleted(first.views.today.single, true);
      await first.setThemeMode(ThemeMode.dark);
      await first.setNotificationsEnabled(true);
      first.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50)); // let the database close

      final restartedGateway = FakeNotificationGateway(permission: NotificationPermissionStatus.granted);
      final second = await makeController(database: AppDatabase(NativeDatabase(file)), gateway: restartedGateway);
      addTearDown(second.dispose);
      expect(second.taskList.single.title, 'Persistent');
      expect(second.views.completed.single.date, DateTime(2026, 3, 10));
      expect(second.themeMode.value, ThemeMode.dark);
      expect(second.reminders.enabled, isTrue);
      expect(restartedGateway.requestCount, 0); // no prompt after a restart
      expect(second.sync.status, SyncStatus.localOnly);
    });
  });

  group('reminders through the controller', () {
    test('permission is requested only when the user turns notifications on', () async {
      final gateway = FakeNotificationGateway();
      final c = await makeController(gateway: gateway);
      addTearDown(c.dispose);
      await c.saveTask(makeTask(id: 'r', due: DateTime(2026, 3, 12), reminder: true, reminderDate: DateTime(2026, 3, 11), reminderMinutes: 540));
      await pumpEventQueue();
      expect(gateway.requestCount, 0);
      expect(gateway.scheduled, isEmpty);

      final status = await c.setNotificationsEnabled(true);
      expect(status, NotificationPermissionStatus.granted);
      expect(gateway.requestCount, 1);
      expect(gateway.lastScheduled.single.key, 'r@2026-03-12');
    });

    test('changes re-plan reminders: complete, reschedule and delete', () async {
      final gateway = FakeNotificationGateway(permission: NotificationPermissionStatus.granted);
      final c = await makeController(gateway: gateway);
      addTearDown(c.dispose);
      await c.setNotificationsEnabled(true);
      await c.saveTask(makeTask(id: 'r', due: DateTime(2026, 3, 12), reminder: true, reminderDate: DateTime(2026, 3, 11), reminderMinutes: 540));
      await pumpEventQueue();
      expect(gateway.lastScheduled.single.key, 'r@2026-03-12');

      await c.reschedule(c.taskList.single, DateTime(2026, 3, 20), null);
      await pumpEventQueue();
      expect(gateway.lastScheduled.single.key, 'r@2026-03-20');
      expect(gateway.lastScheduled.single.at, DateTime(2026, 3, 19, 9));

      await c.setCompleted(c.views.upcoming.single, true);
      await pumpEventQueue();
      expect(gateway.lastScheduled, isEmpty);

      await c.setCompleted(c.views.completed.single, false);
      await pumpEventQueue();
      expect(gateway.lastScheduled.length, 1);

      await c.deleteTask('r');
      await pumpEventQueue();
      expect(gateway.lastScheduled, isEmpty);
    });

    test('turning notifications off cancels everything', () async {
      final gateway = FakeNotificationGateway(permission: NotificationPermissionStatus.granted);
      final c = await makeController(gateway: gateway);
      addTearDown(c.dispose);
      await c.setNotificationsEnabled(true);
      await c.saveTask(makeTask(id: 'r', due: DateTime(2026, 3, 12), reminder: true, reminderDate: DateTime(2026, 3, 11), reminderMinutes: 540));
      await pumpEventQueue();
      expect(c.reminders.planned.length, 1);
      await c.setNotificationsEnabled(false);
      expect(c.reminders.planned, isEmpty);
      expect(c.reminders.isActive, isFalse);
    });
  });
}
