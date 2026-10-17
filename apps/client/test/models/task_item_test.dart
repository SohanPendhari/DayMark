import 'package:daymark/models/recurrence.dart';
import 'package:daymark/models/task_item.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  group('TaskValidator', () {
    Map<String, String> check(TaskItem task, {bool past = true}) =>
        TaskValidator.validate(task, now: kNow, checkReminderInPast: past);

    test('a plain task with a title is valid', () {
      expect(check(makeTask(title: 'Buy milk')), isEmpty);
    });

    test('empty and whitespace titles are rejected', () {
      expect(check(makeTask(title: '')).keys, contains('title'));
      expect(check(makeTask(title: '   \n ')).keys, contains('title'));
      expect(check(makeTask(title: 'x' * 201)).keys, contains('title'));
      expect(check(makeTask(title: 'x' * 200)), isEmpty);
    });

    test('a due time needs a due date, and must be a real time', () {
      expect(check(makeTask(minutes: 600)).keys, contains('dueTime'));
      expect(check(makeTask(due: DateTime(2026, 3, 12), minutes: 1440)).keys, contains('dueTime'));
      expect(check(makeTask(due: DateTime(2026, 3, 12), minutes: -1)).keys, contains('dueTime'));
      expect(check(makeTask(due: DateTime(2026, 3, 12), minutes: 1439)), isEmpty);
    });

    test('absurd due dates are rejected', () {
      expect(check(makeTask(due: DateTime(1999, 12, 31))).keys, contains('dueDate'));
      expect(check(makeTask(due: DateTime(2101, 1, 1))).keys, contains('dueDate'));
    });

    test('repeating tasks need a valid rule and a start date', () {
      expect(check(makeTask(recurrence: const Recurrence.daily())).keys, contains('recurrence'));
      expect(check(makeTask(due: DateTime(2026, 3, 12), recurrence: Recurrence.weekly(<int>{}))).keys, contains('recurrence'));
      expect(check(makeTask(due: DateTime(2026, 3, 12), recurrence: Recurrence.monthly(40))).keys, contains('recurrence'));
      expect(check(makeTask(due: DateTime(2026, 3, 12), recurrence: Recurrence.monthly(31))), isEmpty);
    });

    test('an enabled reminder needs a date and a time', () {
      expect(check(makeTask(reminder: true)).keys, contains('reminder'));
      expect(check(makeTask(reminder: true, reminderDate: DateTime(2026, 3, 11))).keys, contains('reminder'));
    });

    test('a reminder in the past is rejected, unless the reminder is unchanged', () {
      final stale = makeTask(due: DateTime(2026, 3, 10), minutes: 12 * 60, reminder: true, reminderDate: DateTime(2026, 3, 10), reminderMinutes: 9 * 60);
      expect(check(stale).keys, contains('reminder'));
      expect(check(stale, past: false), isEmpty);
    });

    test('a reminder after the due date or time is rejected', () {
      final afterDate = makeTask(due: DateTime(2026, 3, 12), reminder: true, reminderDate: DateTime(2026, 3, 13), reminderMinutes: 540);
      expect(check(afterDate).keys, contains('reminder'));
      final afterTime = makeTask(due: DateTime(2026, 3, 12), minutes: 600, reminder: true, reminderDate: DateTime(2026, 3, 12), reminderMinutes: 601);
      expect(check(afterTime).keys, contains('reminder'));
      final ok = makeTask(due: DateTime(2026, 3, 12), minutes: 600, reminder: true, reminderDate: DateTime(2026, 3, 12), reminderMinutes: 600);
      expect(check(ok), isEmpty);
    });

    test('a completed task is not nagged about a past reminder', () {
      final done = makeTask(due: DateTime(2026, 3, 9), status: TaskStatus.completed, completedAt: kNow, reminder: true, reminderDate: DateTime(2026, 3, 9), reminderMinutes: 540);
      expect(check(done), isEmpty);
    });
  });

  group('reminder timing', () {
    final task = makeTask(due: DateTime(2026, 3, 10), minutes: 600, reminder: true, reminderDate: DateTime(2026, 3, 9), reminderMinutes: 9 * 60);

    test('one-time: fires at the chosen date and time', () {
      expect(task.reminderFor(DateTime(2026, 3, 10)), DateTime(2026, 3, 9, 9));
    });

    test('repeating: keeps the same distance (1 day before) from every occurrence', () {
      final repeating = task.copyWith(recurrence: const Recurrence.daily());
      expect(repeating.reminderFor(DateTime(2026, 3, 17)), DateTime(2026, 3, 16, 9));
      expect(repeating.reminderFor(DateTime(2026, 3, 1)), DateTime(2026, 2, 28, 9));
    });

    test('disabled or incomplete reminders give null', () {
      expect(task.copyWith(reminderEnabled: false).reminderFor(DateTime(2026, 3, 10)), isNull);
      expect(task.copyWith(reminderMinutes: null).reminderFor(DateTime(2026, 3, 10)), isNull);
    });

    test('without a due date the reminder is a plain date and time', () {
      final undated = makeTask(reminder: true, reminderDate: DateTime(2026, 4, 1), reminderMinutes: 75);
      expect(undated.reminderFor(null), DateTime(2026, 4, 1, 1, 15));
    });
  });

  group('copyWith and state changes', () {
    test('copyWith can explicitly clear nullable fields', () {
      final task = makeTask(due: DateTime(2026, 3, 10), minutes: 600);
      expect(task.copyWith(dueDate: null).dueDate, isNull);
      expect(task.copyWith(dueMinutes: null).dueMinutes, isNull);
      expect(task.copyWith(title: 'New').dueDate, DateTime(2026, 3, 10)); // untouched
    });

    test('completed and reopened', () {
      final task = makeTask(due: DateTime(2026, 3, 10));
      final done = task.completed(kNow);
      expect(done.status, TaskStatus.completed);
      expect(done.completedAt, kNow);
      expect(done.updatedAt, kNow);
      final again = done.reopened(DateTime(2026, 3, 11));
      expect(again.status, TaskStatus.pending);
      expect(again.completedAt, isNull);
    });

    test('rescheduling moves the due date and keeps the reminder distance', () {
      final task = makeTask(due: DateTime(2026, 3, 10), minutes: 600, reminder: true, reminderDate: DateTime(2026, 3, 9), reminderMinutes: 540);
      final moved = task.rescheduled(DateTime(2026, 3, 20), 660, kNow);
      expect(moved.dueDate, DateTime(2026, 3, 20));
      expect(moved.dueMinutes, 660);
      expect(moved.reminderDate, DateTime(2026, 3, 19));
      expect(moved.reminderMinutes, 540);
      expect(moved.updatedAt, kNow);
    });

    test('clearing the due date also clears the due time', () {
      final task = makeTask(due: DateTime(2026, 3, 10), minutes: 600);
      final cleared = task.rescheduled(null, 600, kNow);
      expect(cleared.dueDate, isNull);
      expect(cleared.dueMinutes, isNull);
    });
  });
}
