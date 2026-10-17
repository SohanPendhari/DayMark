import '../models/date_utils.dart';
import '../models/recurrence.dart';
import '../models/task_item.dart';
import '../models/task_occurrence.dart';

/// Turns tasks (+ stored completions) into dated occurrences.
///
/// DESIGN: occurrences of a repeating task are NOT stored. They are computed
/// from the rule every time, and only COMPLETIONS are stored (one small row per
/// completed date). Because a pending occurrence has no row, restarting the app
/// or editing a task cannot create duplicates, and completing one occurrence can
/// only ever affect that one date.
class OccurrenceEngine {
  /// Repeating tasks are generated this many days into the future.
  static const int upcomingHorizonDays = 60;

  /// Unfinished occurrences are kept (and shown as overdue) this far back.
  /// Older unfinished occurrences are no longer generated. One-time tasks are
  /// never dropped.
  static const int overdueLookbackDays = 366;

  /// Every date from [from] to [to] (inclusive) on which [rule] produces an
  /// occurrence, never earlier than [start].
  static List<DateTime> datesBetween(
    Recurrence rule,
    DateTime start,
    DateTime from,
    DateTime to,
  ) {
    final first = dateOnly(start).isAfter(dateOnly(from)) ? dateOnly(start) : dateOnly(from);
    final last = dateOnly(to);
    final dates = <DateTime>[];
    if (!rule.isRecurring) return dates;
    for (var day = first; !day.isAfter(last); day = addDays(day, 1)) {
      if (rule.matches(day)) dates.add(day);
    }
    return dates;
  }

  static List<TaskOccurrence> build({
    required List<TaskItem> tasks,
    required List<OccurrenceCompletion> completions,
    required DateTime now,
  }) {
    final today = dateOnly(now);

    final byTask = <String, Map<String, OccurrenceCompletion>>{};
    for (final completion in completions) {
      byTask
          .putIfAbsent(completion.taskId, () => <String, OccurrenceCompletion>{})[
              formatDate(completion.date)] = completion;
    }

    final result = <TaskOccurrence>[];
    for (final task in tasks) {
      final start = task.dueDate;
      if (!task.isRecurring || start == null) {
        result.add(TaskOccurrence(
          task: task,
          date: task.dueDate,
          completedAt: task.status == TaskStatus.completed ? (task.completedAt ?? task.updatedAt) : null,
        ));
        continue;
      }

      final history = byTask[task.id] ?? const <String, OccurrenceCompletion>{};
      final windowStart = addDays(today, -overdueLookbackDays);
      final windowEnd = addDays(today, upcomingHorizonDays);
      final generated = <String>{};
      for (final day in datesBetween(task.recurrence, start, windowStart, windowEnd)) {
        final stamp = formatDate(day);
        generated.add(stamp);
        result.add(TaskOccurrence(task: task, date: day, completedAt: history[stamp]?.completedAt));
      }
      // Completion history is permanent: keep completed dates that the current
      // rule/window no longer generates (the rule was edited, or it is old).
      for (final entry in history.entries) {
        if (!generated.contains(entry.key)) {
          result.add(TaskOccurrence(
            task: task,
            date: entry.value.date,
            completedAt: entry.value.completedAt,
          ));
        }
      }
    }
    return result;
  }
}
