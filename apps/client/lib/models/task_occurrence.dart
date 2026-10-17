import 'date_utils.dart';
import 'task_item.dart';

/// Stable identity of one occurrence: `<taskId>@<yyyy-MM-dd>`, or
/// `<taskId>@none` for a task without a due date. The same occurrence always
/// has the same key, after a restart or after the task is edited.
String occurrenceKey(String taskId, DateTime? date) =>
    '$taskId@${date == null ? 'none' : formatDate(date)}';

/// One dated instance of a task (the only instance for a one-time task).
class TaskOccurrence {
  const TaskOccurrence({required this.task, required this.date, this.completedAt});

  final TaskItem task;

  /// Calendar date this occurrence is due, or null for a task with no due date.
  final DateTime? date;

  /// Non-null when this occurrence has been completed.
  final DateTime? completedAt;

  bool get isCompleted => completedAt != null;
  bool get isRecurring => task.isRecurring;
  String get key => occurrenceKey(task.id, date);
  int? get dueMinutes => task.dueMinutes;

  bool isDueOn(DateTime day) => date != null && isSameDay(date!, day);

  /// The exact due moment, when the task has a due time.
  DateTime? get dueMoment {
    final day = date;
    final minutes = dueMinutes;
    if (day == null || minutes == null) return null;
    return atMinutes(day, minutes);
  }

  /// Instant after which this occurrence counts as overdue: the due time for a
  /// timed task, the end of the due day for a date-only task, null if undated.
  DateTime? get overdueAfter {
    final day = date;
    if (day == null) return null;
    final moment = dueMoment;
    if (moment != null) return moment;
    return DateTime(day.year, day.month, day.day + 1).subtract(const Duration(microseconds: 1));
  }

  /// Unfinished and past its deadline. A task with no due date is NEVER overdue.
  bool isOverdue(DateTime now) {
    final limit = overdueAfter;
    return !isCompleted && limit != null && now.isAfter(limit);
  }

  /// "Overdue · 3 days", "Overdue · 2h", or null when not overdue.
  String? overdueLabel(DateTime now) {
    if (!isOverdue(now)) return null;
    final day = date!;
    if (dueMinutes == null) {
      final n = daysBetween(day, dateOnly(now));
      return n <= 1 ? 'Overdue · 1 day' : 'Overdue · $n days';
    }
    final late = now.difference(overdueAfter!);
    if (late.inDays >= 1) {
      return late.inDays == 1 ? 'Overdue · 1 day' : 'Overdue · ${late.inDays} days';
    }
    if (late.inHours >= 1) return 'Overdue · ${late.inHours}h';
    final mins = late.inMinutes < 1 ? 1 : late.inMinutes;
    return 'Overdue · ${mins}m';
  }
}
