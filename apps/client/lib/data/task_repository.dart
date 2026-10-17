import 'package:drift/drift.dart';

import '../models/date_utils.dart';
import '../models/recurrence.dart';
import '../models/task_item.dart';
import '../models/task_priority.dart';
import 'database/app_database.dart';

/// Everything the app reads from or writes to the task tables.
/// Multi-row changes run in one transaction so a crash cannot leave half a change.
class TaskRepository {
  TaskRepository(this._db);

  final AppDatabase _db;

  Future<List<TaskItem>> loadTasks() async {
    final rows = await _db.select(_db.tasks).get();
    return rows.map(_toItem).toList();
  }

  Future<List<OccurrenceCompletion>> loadCompletions() async {
    final rows = await _db.select(_db.occurrenceCompletions).get();
    final result = <OccurrenceCompletion>[];
    for (final row in rows) {
      final date = parseDate(row.occurrenceDate);
      if (date == null) continue; // ignore a corrupt row rather than crash
      result.add(OccurrenceCompletion(
        taskId: row.taskId,
        date: date,
        completedAt: DateTime.fromMillisecondsSinceEpoch(row.completedAt),
      ));
    }
    return result;
  }

  /// Inserts a new task or replaces the one with the same id.
  Future<void> upsertTask(TaskItem task) async {
    await _db.into(_db.tasks).insertOnConflictUpdate(_toCompanion(task));
  }

  /// Deletes the task and its completion history together.
  Future<void> deleteTask(String id) async {
    await _db.transaction(() async {
      await (_db.delete(_db.occurrenceCompletions)..where((c) => c.taskId.equals(id))).go();
      await (_db.delete(_db.tasks)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Marks ONE occurrence of a repeating task complete (idempotent) and bumps the
  /// task's updatedAt. No other occurrence is touched. Only the columns this
  /// operation owns are written, so a stale copy of the task held by the UI can
  /// never overwrite a more recent edit.
  Future<void> completeOccurrence(String taskId, DateTime date, DateTime at) async {
    await _db.transaction(() async {
      await _db.into(_db.occurrenceCompletions).insertOnConflictUpdate(
            OccurrenceCompletionsCompanion(
              taskId: Value(taskId),
              occurrenceDate: Value(formatDate(date)),
              completedAt: Value(at.millisecondsSinceEpoch),
            ),
          );
      await _touch(taskId, at);
    });
  }

  /// Undoes the completion of one occurrence.
  Future<void> reopenOccurrence(String taskId, DateTime date, DateTime at) async {
    await _db.transaction(() async {
      await (_db.delete(_db.occurrenceCompletions)
            ..where((c) => c.taskId.equals(taskId) & c.occurrenceDate.equals(formatDate(date))))
          .go();
      await _touch(taskId, at);
    });
  }

  /// Completes or reopens a ONE-TIME task. Writes only status, completedAt and
  /// updatedAt (see [completeOccurrence] for why).
  Future<void> setTaskCompleted(String taskId, {required bool completed, required DateTime at}) async {
    await (_db.update(_db.tasks)..where((t) => t.id.equals(taskId))).write(
      TasksCompanion(
        status: Value(completed ? 1 : 0),
        completedAt: Value(completed ? at.millisecondsSinceEpoch : null),
        updatedAt: Value(at.millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> _touch(String taskId, DateTime at) async {
    await (_db.update(_db.tasks)..where((t) => t.id.equals(taskId))).write(
      TasksCompanion(updatedAt: Value(at.millisecondsSinceEpoch)),
    );
  }

  static TaskItem _toItem(TaskRow row) {
    return TaskItem(
      id: row.id,
      title: row.title,
      description: row.description,
      dueDate: parseDate(row.dueDate),
      dueMinutes: row.dueMinutes,
      priority: TaskPriority.fromIndex(row.priority),
      status: row.status == 1 ? TaskStatus.completed : TaskStatus.pending,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      completedAt:
          row.completedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(row.completedAt!),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      reminderEnabled: row.reminderEnabled,
      reminderDate: parseDate(row.reminderDate),
      reminderMinutes: row.reminderMinutes,
      recurrence: Recurrence.fromStorage(
        row.recurrenceType,
        row.recurrenceWeekdays,
        row.recurrenceMonthDay,
      ),
    );
  }

  static TasksCompanion _toCompanion(TaskItem task) {
    final rule = task.recurrence;
    return TasksCompanion(
      id: Value(task.id),
      title: Value(task.title),
      description: Value(task.description),
      dueDate: Value(task.dueDate == null ? null : formatDate(task.dueDate!)),
      dueMinutes: Value(task.dueMinutes),
      priority: Value(task.priority.index),
      status: Value(task.status == TaskStatus.completed ? 1 : 0),
      completedAt: Value(task.completedAt?.millisecondsSinceEpoch),
      createdAt: Value(task.createdAt.millisecondsSinceEpoch),
      updatedAt: Value(task.updatedAt.millisecondsSinceEpoch),
      reminderEnabled: Value(task.reminderEnabled),
      reminderDate: Value(task.reminderDate == null ? null : formatDate(task.reminderDate!)),
      reminderMinutes: Value(task.reminderMinutes),
      recurrenceType: Value(rule.type.index),
      recurrenceWeekdays: Value(rule.weekdayMask),
      recurrenceMonthDay: Value(rule.dayOfMonth),
    );
  }
}
