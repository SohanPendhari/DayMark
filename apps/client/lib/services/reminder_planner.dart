import '../models/date_utils.dart';
import '../models/task_occurrence.dart';

/// One notification that should be delivered.
class PlannedReminder {
  const PlannedReminder({
    required this.key,
    required this.notificationId,
    required this.at,
    required this.title,
    required this.body,
  });

  /// Occurrence key (`<taskId>@<date>`), also used as the notification payload.
  final String key;

  /// Stable per occurrence, so re-planning replaces a notification instead of
  /// duplicating it.
  final int notificationId;
  final DateTime at;
  final String title;
  final String body;
}

/// Decides which reminders should exist right now. Pure and deterministic: the
/// same tasks and the same time always give the same plan.
///
/// A reminder is planned only if its occurrence is unfinished, its time is in
/// the future and within [horizonDays]. Completed, deleted, or rescheduled
/// tasks therefore simply stop appearing in the plan, and re-planning replaces
/// whatever was scheduled before.
class ReminderPlanner {
  static const int defaultHorizonDays = 30;

  /// Platforms limit pending notifications (iOS: 64), so only the soonest are planned.
  static const int defaultMaxReminders = 50;

  static List<PlannedReminder> plan(
    List<TaskOccurrence> occurrences,
    DateTime now, {
    int horizonDays = defaultHorizonDays,
    int maxReminders = defaultMaxReminders,
  }) {
    // Same time of day, [horizonDays] later. (addDays() would round to midnight.)
    final limit = DateTime(now.year, now.month, now.day + horizonDays, now.hour, now.minute, now.second);
    final candidates = <PlannedReminder>[];
    for (final occurrence in occurrences) {
      if (occurrence.isCompleted) continue;
      final at = occurrence.task.reminderFor(occurrence.date);
      if (at == null || !at.isAfter(now) || at.isAfter(limit)) continue;
      candidates.add(PlannedReminder(
        key: occurrence.key,
        notificationId: 0,
        at: at,
        title: occurrence.task.title,
        body: _body(occurrence, now),
      ));
    }
    candidates.sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });

    final used = <int>{};
    final planned = <PlannedReminder>[];
    for (final c in candidates.take(maxReminders)) {
      var id = stableId(c.key);
      while (!used.add(id)) {
        id = (id + 1) & 0x7fffffff; // resolve the (unlikely) collision deterministically
      }
      planned.add(PlannedReminder(
        key: c.key,
        notificationId: id,
        at: c.at,
        title: c.title,
        body: c.body,
      ));
    }
    return planned;
  }

  /// Positive 31-bit id derived from the key. Kept small enough that the
  /// arithmetic is exact on Flutter Web, where integers are JavaScript numbers.
  static int stableId(String key) {
    var hash = 7;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }

  static String _body(TaskOccurrence occurrence, DateTime now) {
    final date = occurrence.date;
    if (date == null) return 'Reminder';
    final minutes = occurrence.dueMinutes;
    var day = describeDay(date, now);
    if (day == 'Today' || day == 'Tomorrow' || day == 'Yesterday') day = day.toLowerCase();
    return minutes == null ? 'Due $day' : 'Due $day at ${formatMinutes(minutes)}';
  }
}
