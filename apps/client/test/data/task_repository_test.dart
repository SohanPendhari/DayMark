import 'dart:io';

import 'package:daymark/data/database/app_database.dart';
import 'package:daymark/data/settings_repository.dart';
import 'package:daymark/data/task_repository.dart';
import 'package:daymark/models/recurrence.dart';
import 'package:daymark/models/task_item.dart';
import 'package:daymark/models/task_priority.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late TaskRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TaskRepository(db);
  });

  tearDown(() => db.close());

  test('the schema is versioned', () {
    expect(AppDatabase.currentSchemaVersion, 1);
    expect(db.schemaVersion, 1);
  });

  test('indexes exist for the common queries', () async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
        .get();
    final names = rows.map((r) => r.read<String>('name')).toSet();
    expect(names, containsAll(<String>[
      'tasks_due_date_idx',
      'tasks_status_idx',
      'tasks_updated_at_idx',
      'completions_task_idx',
    ]));
  });

  test('a fully populated task survives a round trip', () async {
    final task = TaskItem(
      id: 'full',
      title: 'Pay rent',
      description: 'Bank transfer',
      dueDate: DateTime(2026, 3, 31),
      dueMinutes: 17 * 60 + 30,
      priority: TaskPriority.high,
      status: TaskStatus.completed,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      completedAt: DateTime.fromMillisecondsSinceEpoch(1700000500000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000600000),
      reminderEnabled: true,
      reminderDate: DateTime(2026, 3, 30),
      reminderMinutes: 9 * 60,
      recurrence: Recurrence.monthly(31),
    );
    await repo.upsertTask(task);
    final loaded = (await repo.loadTasks()).single;
    expect(loaded.id, 'full');
    expect(loaded.title, 'Pay rent');
    expect(loaded.description, 'Bank transfer');
    expect(loaded.dueDate, DateTime(2026, 3, 31));
    expect(loaded.dueMinutes, 1050);
    expect(loaded.priority, TaskPriority.high);
    expect(loaded.status, TaskStatus.completed);
    expect(loaded.createdAt, task.createdAt);
    expect(loaded.completedAt, task.completedAt);
    expect(loaded.updatedAt, task.updatedAt);
    expect(loaded.reminderEnabled, isTrue);
    expect(loaded.reminderDate, DateTime(2026, 3, 30));
    expect(loaded.reminderMinutes, 540);
    expect(loaded.recurrence, Recurrence.monthly(31));
  });

  test('a minimal task keeps its nulls and defaults', () async {
    await repo.upsertTask(makeTask(id: 'min', title: 'Just a title'));
    final loaded = (await repo.loadTasks()).single;
    expect(loaded.description, isNull);
    expect(loaded.dueDate, isNull);
    expect(loaded.dueMinutes, isNull);
    expect(loaded.completedAt, isNull);
    expect(loaded.reminderEnabled, isFalse);
    expect(loaded.recurrence.isRecurring, isFalse);
    expect(loaded.status, TaskStatus.pending);
  });

  test('weekly rules round trip', () async {
    await repo.upsertTask(makeTask(id: 'w', due: DateTime(2026, 3, 2), recurrence: Recurrence.weekly(<int>{1, 3, 5})));
    expect((await repo.loadTasks()).single.recurrence, Recurrence.weekly(<int>{1, 3, 5}));
  });

  test('saving the same id again updates instead of duplicating', () async {
    await repo.upsertTask(makeTask(id: 'x', title: 'Old'));
    await repo.upsertTask(makeTask(id: 'x', title: 'New'));
    final all = await repo.loadTasks();
    expect(all.length, 1);
    expect(all.single.title, 'New');
  });

  test('deleting a task also deletes its completion history, and nothing else', () async {
    final series = makeTask(id: 'series', due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
    final other = makeTask(id: 'other', due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
    await repo.upsertTask(series);
    await repo.upsertTask(other);
    await repo.completeOccurrence(series.id, DateTime(2026, 3, 2), kNow);
    await repo.completeOccurrence(other.id, DateTime(2026, 3, 2), kNow);
    await repo.deleteTask('series');
    expect((await repo.loadTasks()).map((t) => t.id), <String>['other']);
    expect((await repo.loadCompletions()).map((c) => c.taskId), <String>['other']);
  });

  test('completing an occurrence is idempotent and independent of other dates', () async {
    final task = makeTask(due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
    await repo.upsertTask(task);
    await repo.completeOccurrence(task.id, DateTime(2026, 3, 3), kNow);
    await repo.completeOccurrence(task.id, DateTime(2026, 3, 3), kNow.add(const Duration(minutes: 5)));
    await repo.completeOccurrence(task.id, DateTime(2026, 3, 4), kNow);
    final done = await repo.loadCompletions();
    expect(done.length, 2);
    expect(done.map((c) => c.date), containsAll(<DateTime>[DateTime(2026, 3, 3), DateTime(2026, 3, 4)]));
  });

  test('reopening removes only that occurrence and bumps the task update time', () async {
    final task = makeTask(due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
    await repo.upsertTask(task);
    await repo.completeOccurrence(task.id, DateTime(2026, 3, 3), kNow);
    await repo.completeOccurrence(task.id, DateTime(2026, 3, 4), kNow);
    final later = kNow.add(const Duration(hours: 1));
    await repo.reopenOccurrence(task.id, DateTime(2026, 3, 3), later);
    expect((await repo.loadCompletions()).single.date, DateTime(2026, 3, 4));
    expect((await repo.loadTasks()).single.updatedAt, later);
  });

  test('completing never overwrites a newer edit made through another copy of the task', () async {
    final original = makeTask(id: 's', title: 'Original', due: DateTime(2026, 3, 10));
    await repo.upsertTask(original);
    await repo.upsertTask(original.copyWith(title: 'Edited later')); // the UI still holds `original`
    await repo.setTaskCompleted('s', completed: true, at: kNow);
    final saved = (await repo.loadTasks()).single;
    expect(saved.title, 'Edited later');
    expect(saved.status, TaskStatus.completed);
    expect(saved.completedAt, kNow);
    await repo.setTaskCompleted('s', completed: false, at: kNow);
    expect((await repo.loadTasks()).single.completedAt, isNull);

    final series = makeTask(id: 'r', title: 'Series', due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
    await repo.upsertTask(series);
    await repo.upsertTask(series.copyWith(title: 'Series renamed'));
    await repo.completeOccurrence('r', DateTime(2026, 3, 2), kNow);
    expect((await repo.loadTasks()).firstWhere((t) => t.id == 'r').title, 'Series renamed');
  });

  test('a corrupt completion row is ignored rather than crashing the app', () async {
    await db.customStatement(
        "INSERT INTO occurrence_completions (task_id, occurrence_date, completed_at) VALUES ('t', 'garbage', 1)");
    expect(await repo.loadCompletions(), isEmpty);
  });

  test('settings can be written, overwritten and read', () async {
    final settings = SettingsRepository(db);
    expect(await settings.read('themeMode'), isNull);
    await settings.write('themeMode', 'dark');
    await settings.write('themeMode', 'system');
    expect(await settings.read('themeMode'), 'system');
  });

  test('data survives closing and reopening the database (an app restart)', () async {
    final dir = Directory.systemTemp.createTempSync('daymark_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/daymark.sqlite');

    final first = AppDatabase(NativeDatabase(file));
    final firstRepo = TaskRepository(first);
    final series = makeTask(id: 'persist', title: 'Survives restarts', due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
    await firstRepo.upsertTask(series);
    await firstRepo.completeOccurrence(series.id, DateTime(2026, 3, 2), kNow);
    await SettingsRepository(first).write('themeMode', 'dark');
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    final tasks = await TaskRepository(second).loadTasks();
    expect(tasks.single.title, 'Survives restarts');
    expect((await TaskRepository(second).loadCompletions()).single.date, DateTime(2026, 3, 2));
    expect(await SettingsRepository(second).read('themeMode'), 'dark');
  });
}
