import 'package:daymark/models/recurrence.dart';
import 'package:daymark/models/task_item.dart';
import 'package:daymark/models/task_occurrence.dart';
import 'package:daymark/models/task_priority.dart';
import 'package:daymark/models/task_views.dart';
import 'package:daymark/services/occurrence_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

TaskViews viewsOf(List<TaskItem> tasks, {List<OccurrenceCompletion> completions = const <OccurrenceCompletion>[], DateTime? now}) {
  final at = now ?? kNow;
  return TaskViews.build(OccurrenceEngine.build(tasks: tasks, completions: completions, now: at), at);
}

List<String> ids(List<TaskOccurrence> list) => list.map((o) => o.task.id).toList();

void main() {
  // "now" is Tuesday 10 March 2026, 10:00.
  final tasks = <TaskItem>[
    makeTask(id: 'a', title: 'Timed, already past', due: DateTime(2026, 3, 10), minutes: 9 * 60),
    makeTask(id: 'b', title: 'Timed, later today', due: DateTime(2026, 3, 10), minutes: 18 * 60),
    makeTask(id: 'c', title: 'All day today', due: DateTime(2026, 3, 10)),
    makeTask(id: 'd', title: 'Yesterday', due: DateTime(2026, 3, 9)),
    makeTask(id: 'e', title: 'Tomorrow', due: DateTime(2026, 3, 11)),
    makeTask(id: 'f', title: 'No due date'),
    makeTask(id: 'g', title: 'Done earlier', due: DateTime(2026, 3, 5), status: TaskStatus.completed, completedAt: DateTime(2026, 3, 5, 12)),
    makeTask(id: 'h', title: 'Undated done', status: TaskStatus.completed, completedAt: DateTime(2026, 3, 8, 12)),
    makeTask(id: 'i', title: 'Done today', due: DateTime(2026, 3, 10), minutes: 8 * 60, status: TaskStatus.completed, completedAt: DateTime(2026, 3, 10, 8, 5)),
  ];

  test('Today lists everything due today, unfinished first, timed before all-day', () {
    expect(ids(viewsOf(tasks).today), <String>['a', 'b', 'c', 'i']);
  });

  test('Overdue contains unfinished tasks past their deadline, oldest first', () {
    // d: yesterday. a: today but its time has passed. c (all day today) is not overdue yet.
    expect(ids(viewsOf(tasks).overdue), <String>['d', 'a']);
  });

  test('a task without a due date is never overdue', () {
    final views = viewsOf(<TaskItem>[makeTask(id: 'f')], now: DateTime(2030, 1, 1));
    expect(views.overdue, isEmpty);
    expect(views.today, isEmpty);
    expect(views.upcoming, isEmpty);
    expect(ids(views.all), <String>['f']);
  });

  test('Upcoming is unfinished and due after today', () {
    expect(ids(viewsOf(tasks).upcoming), <String>['e']);
  });

  test('Completed shows finished tasks, newest first', () {
    expect(ids(viewsOf(tasks).completed), <String>['i', 'h', 'g']);
  });

  test('All lists every task once, pending first, undated after dated', () {
    final all = viewsOf(tasks).all;
    expect(all.length, tasks.length);
    expect(ids(all), <String>['d', 'a', 'b', 'c', 'e', 'f', 'g', 'i', 'h']);
  });

  test('counts and progress use real data', () {
    final views = viewsOf(tasks);
    expect(views.todayCompleted, 1);
    expect(views.todayPending, 3);
    expect(views.todayProgress, 0.25);
    expect(views.countFor(TaskTab.today), 3);
    expect(views.countFor(TaskTab.overdue), 2);
    expect(views.countFor(TaskTab.upcoming), 1);
    expect(views.countFor(TaskTab.completed), 3);
    expect(views.countFor(TaskTab.all), 9);
  });

  test('progress with no tasks today is 0, not a division error', () {
    expect(viewsOf(const <TaskItem>[]).todayProgress, 0);
    expect(TaskViews.empty.todayProgress, 0);
  });

  group('overdue boundaries', () {
    TaskOccurrence timed() => TaskOccurrence(task: makeTask(due: DateTime(2026, 3, 10), minutes: 600), date: DateTime(2026, 3, 10));
    TaskOccurrence dateOnlyTask() => TaskOccurrence(task: makeTask(due: DateTime(2026, 3, 9)), date: DateTime(2026, 3, 9));

    test('a timed task is not overdue at its exact time, but is a moment later', () {
      expect(timed().isOverdue(DateTime(2026, 3, 10, 10, 0)), isFalse);
      expect(timed().isOverdue(DateTime(2026, 3, 10, 10, 0, 0, 1)), isTrue);
    });

    test('a date-only task becomes overdue at midnight, not before', () {
      expect(dateOnlyTask().isOverdue(DateTime(2026, 3, 9, 23, 59, 59)), isFalse);
      expect(dateOnlyTask().isOverdue(DateTime(2026, 3, 10, 0, 0, 0)), isTrue);
    });

    test('a completed task is never overdue', () {
      final done = TaskOccurrence(task: makeTask(due: DateTime(2020, 1, 1)), date: DateTime(2020, 1, 1), completedAt: DateTime(2020, 1, 1));
      expect(done.isOverdue(kNow), isFalse);
    });

    test('overdue labels', () {
      expect(dateOnlyTask().overdueLabel(DateTime(2026, 3, 10, 9)), 'Overdue · 1 day');
      final older = TaskOccurrence(task: makeTask(due: DateTime(2026, 3, 5)), date: DateTime(2026, 3, 5));
      expect(older.overdueLabel(kNow), 'Overdue · 5 days');
      expect(timed().overdueLabel(DateTime(2026, 3, 10, 12, 30)), 'Overdue · 2h');
      expect(timed().overdueLabel(DateTime(2026, 3, 10, 10, 15)), 'Overdue · 15m');
      expect(timed().overdueLabel(DateTime(2026, 3, 10, 9)), isNull);
    });
  });

  group('repeating tasks across views', () {
    final daily = makeTask(id: 'r', title: 'Daily', due: DateTime(2026, 3, 8), recurrence: const Recurrence.daily());

    test('completing today only completes today; tomorrow stays upcoming', () {
      final done = OccurrenceCompletion(taskId: 'r', date: DateTime(2026, 3, 10), completedAt: DateTime(2026, 3, 10, 9));
      final views = viewsOf(<TaskItem>[daily], completions: <OccurrenceCompletion>[done]);
      expect(views.today.single.isCompleted, isTrue);
      expect(views.upcoming.first.date, DateTime(2026, 3, 11));
      expect(views.upcoming.every((o) => !o.isCompleted), isTrue);
      // 8 and 9 March are still unfinished and overdue.
      expect(views.overdue.map((o) => o.date), <DateTime>[DateTime(2026, 3, 8), DateTime(2026, 3, 9)]);
    });

    test('All shows one row for the series: its earliest unfinished occurrence', () {
      final all = viewsOf(<TaskItem>[daily]).all;
      expect(all.length, 1);
      expect(all.single.date, DateTime(2026, 3, 8));
    });

    test('Completed lists each finished occurrence separately', () {
      final done = <OccurrenceCompletion>[
        OccurrenceCompletion(taskId: 'r', date: DateTime(2026, 3, 8), completedAt: DateTime(2026, 3, 8, 9)),
        OccurrenceCompletion(taskId: 'r', date: DateTime(2026, 3, 9), completedAt: DateTime(2026, 3, 9, 9)),
      ];
      final views = viewsOf(<TaskItem>[daily], completions: done);
      expect(views.completed.length, 2);
      expect(views.completed.first.date, DateTime(2026, 3, 9));
    });
  });

  test('priority breaks ties between tasks with the same time', () {
    final views = viewsOf(<TaskItem>[
      makeTask(id: 'lo', title: 'B low', due: DateTime(2026, 3, 10), priority: TaskPriority.low),
      makeTask(id: 'hi', title: 'A high', due: DateTime(2026, 3, 10), priority: TaskPriority.high),
      makeTask(id: 'md', title: 'C medium', due: DateTime(2026, 3, 10)),
    ]);
    expect(ids(views.today), <String>['hi', 'md', 'lo']);
  });
}
