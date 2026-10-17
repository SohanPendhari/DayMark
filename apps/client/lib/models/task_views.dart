import 'date_utils.dart';
import 'task_occurrence.dart';

enum TaskTab { today, upcoming, overdue, completed, all }

/// The five task lists, derived from occurrences and the current time.
///
/// * today     - due today, finished or not (a timed task whose time has passed
///               also appears in [overdue]).
/// * upcoming  - unfinished, due after today.
/// * overdue   - unfinished and past its deadline. Undated tasks never appear.
/// * completed - finished occurrences (history), newest first.
/// * all       - one entry per task, including tasks without a due date. A
///               repeating task is represented by its earliest unfinished
///               occurrence (its latest completed one if none is pending).
class TaskViews {
  const TaskViews({
    required this.today,
    required this.upcoming,
    required this.overdue,
    required this.completed,
    required this.all,
  });

  final List<TaskOccurrence> today;
  final List<TaskOccurrence> upcoming;
  final List<TaskOccurrence> overdue;
  final List<TaskOccurrence> completed;
  final List<TaskOccurrence> all;

  static const TaskViews empty = TaskViews(
    today: <TaskOccurrence>[],
    upcoming: <TaskOccurrence>[],
    overdue: <TaskOccurrence>[],
    completed: <TaskOccurrence>[],
    all: <TaskOccurrence>[],
  );

  int get todayCompleted => today.where((o) => o.isCompleted).length;
  int get todayPending => today.length - todayCompleted;

  /// Completed share of today's tasks, 0 when there are none (never divides by zero).
  double get todayProgress => today.isEmpty ? 0 : todayCompleted / today.length;

  List<TaskOccurrence> forTab(TaskTab tab) {
    switch (tab) {
      case TaskTab.today:
        return today;
      case TaskTab.upcoming:
        return upcoming;
      case TaskTab.overdue:
        return overdue;
      case TaskTab.completed:
        return completed;
      case TaskTab.all:
        return all;
    }
  }

  /// Badge count: unfinished tasks for Today, list length for the others.
  int countFor(TaskTab tab) => tab == TaskTab.today ? todayPending : forTab(tab).length;

  static TaskViews build(List<TaskOccurrence> occurrences, DateTime now) {
    final today = dateOnly(now);

    final todayList = occurrences.where((o) => o.isDueOn(today)).toList()..sort(_byDay);
    final upcoming = occurrences
        .where((o) => !o.isCompleted && o.date != null && o.date!.isAfter(today))
        .toList()
      ..sort(_byDate);
    final overdue = occurrences.where((o) => o.isOverdue(now)).toList()..sort(_byDate);
    final completed = occurrences.where((o) => o.isCompleted).toList()
      ..sort((a, b) => b.completedAt!.compareTo(a.completedAt!));
    final all = _representatives(occurrences)..sort(_byAll);

    return TaskViews(
      today: todayList,
      upcoming: upcoming,
      overdue: overdue,
      completed: completed,
      all: all,
    );
  }

  static List<TaskOccurrence> _representatives(List<TaskOccurrence> occurrences) {
    final groups = <String, List<TaskOccurrence>>{};
    for (final occurrence in occurrences) {
      groups.putIfAbsent(occurrence.task.id, () => <TaskOccurrence>[]).add(occurrence);
    }
    final result = <TaskOccurrence>[];
    for (final group in groups.values) {
      if (group.length == 1) {
        result.add(group.first);
        continue;
      }
      final pending = group.where((o) => !o.isCompleted).toList()..sort(_byDate);
      if (pending.isNotEmpty) {
        result.add(pending.first);
      } else {
        final done = List<TaskOccurrence>.of(group)..sort(_byDate);
        result.add(done.last);
      }
    }
    return result;
  }

  static const int _noTime = 100000; // sorts untimed tasks after timed ones

  static int _byTimeThenPriority(TaskOccurrence a, TaskOccurrence b) {
    final time = (a.dueMinutes ?? _noTime).compareTo(b.dueMinutes ?? _noTime);
    if (time != 0) return time;
    final priority = b.task.priority.index.compareTo(a.task.priority.index);
    if (priority != 0) return priority;
    return a.task.title.toLowerCase().compareTo(b.task.title.toLowerCase());
  }

  static int _byDay(TaskOccurrence a, TaskOccurrence b) {
    if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
    return _byTimeThenPriority(a, b);
  }

  static int _byDate(TaskOccurrence a, TaskOccurrence b) {
    final left = a.date;
    final right = b.date;
    if (left != null && right != null) {
      final day = left.compareTo(right);
      if (day != 0) return day;
    } else if (left == null && right != null) {
      return 1;
    } else if (left != null && right == null) {
      return -1;
    }
    return _byTimeThenPriority(a, b);
  }

  static int _byAll(TaskOccurrence a, TaskOccurrence b) {
    if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
    return _byDate(a, b);
  }
}
