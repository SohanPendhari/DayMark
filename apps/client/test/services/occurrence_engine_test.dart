import 'package:daymark/models/date_utils.dart';
import 'package:daymark/models/recurrence.dart';
import 'package:daymark/models/task_item.dart';
import 'package:daymark/models/task_views.dart';
import 'package:daymark/services/occurrence_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

List<String> iso(List<DateTime> dates) => dates.map(formatDate).toList();

List<String> dates(Recurrence rule, DateTime start, DateTime from, DateTime to) =>
    iso(OccurrenceEngine.datesBetween(rule, start, from, to));

void main() {
  // Expected lists below were produced by an independent Python implementation.
  group('month-end handling', () {
    test('day 31 through 2026', () {
      expect(
        dates(Recurrence.monthly(31), DateTime(2026, 1, 31), DateTime(2026, 1, 31), DateTime(2026, 12, 31)),
        <String>[
          '2026-01-31', '2026-02-28', '2026-03-31', '2026-04-30', '2026-05-31', '2026-06-30',
          '2026-07-31', '2026-08-31', '2026-09-30', '2026-10-31', '2026-11-30', '2026-12-31',
        ],
      );
    });

    test('day 31 in a leap year uses 29 February', () {
      expect(
        dates(Recurrence.monthly(31), DateTime(2028, 1, 31), DateTime(2028, 1, 31), DateTime(2028, 4, 30)),
        <String>['2028-01-31', '2028-02-29', '2028-03-31', '2028-04-30'],
      );
    });

    test('day 29: 28 Feb in 2027, 29 Feb in 2028', () {
      expect(
        dates(Recurrence.monthly(29), DateTime(2027, 1, 1), DateTime(2027, 1, 1), DateTime(2027, 3, 31)),
        <String>['2027-01-29', '2027-02-28', '2027-03-29'],
      );
      expect(
        dates(Recurrence.monthly(29), DateTime(2028, 1, 1), DateTime(2028, 1, 1), DateTime(2028, 3, 31)),
        <String>['2028-01-29', '2028-02-29', '2028-03-29'],
      );
    });

    test('day 30 in February', () {
      expect(
        dates(Recurrence.monthly(30), DateTime(2026, 1, 1), DateTime(2026, 1, 1), DateTime(2026, 4, 30)),
        <String>['2026-01-30', '2026-02-28', '2026-03-30', '2026-04-30'],
      );
    });

    test('2100 is not a leap year', () {
      expect(
        dates(Recurrence.monthly(31), DateTime(2100, 1, 31), DateTime(2100, 1, 31), DateTime(2100, 3, 31)),
        <String>['2100-01-31', '2100-02-28', '2100-03-31'],
      );
    });

    test('months are computed from the rule, so there is no drift after February', () {
      final list = dates(
          Recurrence.monthly(31), DateTime(2026, 1, 31), DateTime(2026, 1, 31), DateTime(2026, 3, 31));
      expect(list.last, '2026-03-31'); // not 2026-03-28
    });

    test('a day before the start date does not produce an occurrence', () {
      expect(
        dates(Recurrence.monthly(15), DateTime(2026, 1, 20), DateTime(2026, 1, 1), DateTime(2026, 4, 30)),
        <String>['2026-02-15', '2026-03-15', '2026-04-15'],
      );
    });
  });

  group('weekly and daily', () {
    test('Monday, Wednesday, Friday', () {
      expect(
        dates(Recurrence.weekly(<int>{1, 3, 5}), DateTime(2026, 3, 2), DateTime(2026, 3, 2), DateTime(2026, 3, 15)),
        <String>[
          '2026-03-02', '2026-03-04', '2026-03-06', '2026-03-09', '2026-03-11', '2026-03-13',
        ],
      );
    });

    test('starting mid-week skips earlier weekdays', () {
      expect(
        dates(Recurrence.weekly(<int>{1, 5}), DateTime(2026, 3, 4), DateTime(2026, 3, 4), DateTime(2026, 3, 16)),
        <String>['2026-03-06', '2026-03-09', '2026-03-13', '2026-03-16'],
      );
    });

    test('Sundays only', () {
      expect(
        dates(Recurrence.weekly(<int>{7}), DateTime(2026, 3, 1), DateTime(2026, 3, 1), DateTime(2026, 3, 31)),
        <String>['2026-03-01', '2026-03-08', '2026-03-15', '2026-03-22', '2026-03-29'],
      );
    });

    test('daily bounds are inclusive; spring-forward weeks have no skipped or doubled day', () {
      expect(
        dates(const Recurrence.daily(), DateTime(2026, 3, 1), DateTime(2026, 3, 1), DateTime(2026, 3, 5)),
        <String>['2026-03-01', '2026-03-02', '2026-03-03', '2026-03-04', '2026-03-05'],
      );
      final across = OccurrenceEngine.datesBetween(
          const Recurrence.daily(), DateTime(2026, 3, 6), DateTime(2026, 3, 6), DateTime(2026, 3, 31));
      expect(across.length, 26);
      expect(across.toSet().length, 26);
    });

    test('a non-repeating rule yields nothing', () {
      expect(OccurrenceEngine.datesBetween(const Recurrence.none(), DateTime(2026, 3, 1), DateTime(2026, 3, 1), DateTime(2026, 3, 9)), isEmpty);
    });
  });

  group('building occurrences', () {
    test('one-time tasks, including undated ones, produce exactly one occurrence', () {
      final tasks = <TaskItem>[
        makeTask(id: 'a', due: DateTime(2026, 3, 12)),
        makeTask(id: 'b'),
      ];
      final result = OccurrenceEngine.build(tasks: tasks, completions: const <OccurrenceCompletion>[], now: kNow);
      expect(result.map((o) => o.key), <String>['a@2026-03-12', 'b@none']);
    });

    test('a repeating task is generated from the lookback window to the horizon', () {
      final task = makeTask(due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
      final result = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: const <OccurrenceCompletion>[], now: kNow);
      expect(result.length, 70); // 2026-03-01 .. 2026-05-09
      expect(formatDate(result.first.date!), '2026-03-01');
      expect(formatDate(result.last.date!), '2026-05-09');
    });

    test('very old unfinished occurrences stop being generated after the lookback', () {
      final task = makeTask(due: DateTime(2024, 1, 1), recurrence: const Recurrence.daily());
      final result = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: const <OccurrenceCompletion>[], now: kNow);
      expect(formatDate(result.first.date!), '2025-03-09');
      expect(result.length, 427);
    });

    test('completing one occurrence completes only that date', () {
      final task = makeTask(due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
      final done = OccurrenceCompletion(taskId: 't1', date: DateTime(2026, 3, 3), completedAt: DateTime(2026, 3, 3, 8));
      final result = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: <OccurrenceCompletion>[done], now: kNow);
      final completed = result.where((o) => o.isCompleted).toList();
      expect(completed.length, 1);
      expect(formatDate(completed.single.date!), '2026-03-03');
      expect(result.where((o) => !o.isCompleted).length, 69);
    });

    test('rebuilding (restart, edit, reload) never duplicates occurrences', () {
      final task = makeTask(due: DateTime(2026, 3, 1), recurrence: Recurrence.weekly(<int>{1, 4}));
      final first = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: const <OccurrenceCompletion>[], now: kNow);
      final second = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: const <OccurrenceCompletion>[], now: kNow);
      final keys = first.map((o) => o.key).toList();
      expect(keys.toSet().length, keys.length);
      expect(second.map((o) => o.key).toList(), keys);
    });

    test('editing the rule keeps completed history that the new rule no longer generates', () {
      // 2026-03-04 is a Wednesday. The task now repeats on Mondays only.
      final task = makeTask(due: DateTime(2026, 3, 1), recurrence: Recurrence.weekly(<int>{1}));
      final done = OccurrenceCompletion(taskId: 't1', date: DateTime(2026, 3, 4), completedAt: DateTime(2026, 3, 4, 9));
      final result = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: <OccurrenceCompletion>[done], now: kNow);
      final kept = result.where((o) => o.key == 't1@2026-03-04').toList();
      expect(kept.length, 1);
      expect(kept.single.isCompleted, isTrue);
    });

    test('completions of other tasks never leak into a task', () {
      final a = makeTask(id: 'a', due: DateTime(2026, 3, 8), recurrence: const Recurrence.daily());
      final b = makeTask(id: 'b', due: DateTime(2026, 3, 8), recurrence: const Recurrence.daily());
      final done = OccurrenceCompletion(taskId: 'a', date: DateTime(2026, 3, 9), completedAt: DateTime(2026, 3, 9, 7));
      final result = OccurrenceEngine.build(tasks: <TaskItem>[a, b], completions: <OccurrenceCompletion>[done], now: kNow);
      expect(result.firstWhere((o) => o.key == 'a@2026-03-09').isCompleted, isTrue);
      expect(result.firstWhere((o) => o.key == 'b@2026-03-09').isCompleted, isFalse);
    });

    test('unfinished past occurrences are preserved as overdue', () {
      final task = makeTask(due: DateTime(2026, 3, 1), recurrence: const Recurrence.daily());
      final result = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: const <OccurrenceCompletion>[], now: kNow);
      final views = TaskViews.build(result, kNow);
      // 1 March .. 9 March are past (today, 10 March, is still open).
      expect(views.overdue.length, 9);
      expect(formatDate(views.overdue.first.date!), '2026-03-01');
    });

    test('a completed one-time task keeps its completion time', () {
      final at = DateTime(2026, 3, 9, 18);
      final task = makeTask(due: DateTime(2026, 3, 9), status: TaskStatus.completed, completedAt: at);
      final result = OccurrenceEngine.build(tasks: <TaskItem>[task], completions: const <OccurrenceCompletion>[], now: kNow);
      expect(result.single.completedAt, at);
    });
  });
}
