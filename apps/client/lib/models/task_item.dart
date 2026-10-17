import 'date_utils.dart';
import 'recurrence.dart';
import 'task_priority.dart';

enum TaskStatus { pending, completed }

const Object _keep = Object();

/// A task, or for a repeating task the whole series.
///
/// * [dueDate] is a local calendar date (midnight); [dueMinutes] is an optional
///   time of day in minutes since midnight. A time without a date is invalid.
/// * [status] / [completedAt] describe a ONE-TIME task. For a repeating task
///   each occurrence is completed separately (see OccurrenceCompletion), so
///   completing one never completes another.
/// * The reminder is stored as a date + time. For a repeating task it is applied
///   at the same distance from every occurrence (see [reminderFor]).
/// * [updatedAt] is bumped on every change, ready for future synchronization.
class TaskItem {
  const TaskItem({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.dueDate,
    this.dueMinutes,
    this.priority = TaskPriority.medium,
    this.status = TaskStatus.pending,
    this.completedAt,
    this.reminderEnabled = false,
    this.reminderDate,
    this.reminderMinutes,
    this.recurrence = const Recurrence.none(),
  });

  final String id;
  final String title;
  final String? description;
  final DateTime? dueDate;
  final int? dueMinutes;
  final TaskPriority priority;
  final TaskStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;
  final DateTime updatedAt;
  final bool reminderEnabled;
  final DateTime? reminderDate;
  final int? reminderMinutes;
  final Recurrence recurrence;

  bool get isRecurring => recurrence.isRecurring;

  /// Copy with changes. Nullable fields can be set to null explicitly:
  /// `task.copyWith(dueDate: null)` clears the due date.
  TaskItem copyWith({
    String? title,
    Object? description = _keep,
    Object? dueDate = _keep,
    Object? dueMinutes = _keep,
    TaskPriority? priority,
    TaskStatus? status,
    Object? completedAt = _keep,
    DateTime? updatedAt,
    bool? reminderEnabled,
    Object? reminderDate = _keep,
    Object? reminderMinutes = _keep,
    Recurrence? recurrence,
  }) {
    return TaskItem(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      description: identical(description, _keep) ? this.description : description as String?,
      dueDate: identical(dueDate, _keep) ? this.dueDate : dueDate as DateTime?,
      dueMinutes: identical(dueMinutes, _keep) ? this.dueMinutes : dueMinutes as int?,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      completedAt: identical(completedAt, _keep) ? this.completedAt : completedAt as DateTime?,
      reminderEnabled: reminderEnabled ?? this.reminderEnabled,
      reminderDate: identical(reminderDate, _keep) ? this.reminderDate : reminderDate as DateTime?,
      reminderMinutes:
          identical(reminderMinutes, _keep) ? this.reminderMinutes : reminderMinutes as int?,
      recurrence: recurrence ?? this.recurrence,
    );
  }

  /// One-time task marked complete.
  TaskItem completed(DateTime at) =>
      copyWith(status: TaskStatus.completed, completedAt: at, updatedAt: at);

  /// One-time task marked pending again.
  TaskItem reopened(DateTime at) =>
      copyWith(status: TaskStatus.pending, completedAt: null, updatedAt: at);

  /// Moves the due date/time. A reminder keeps its distance from the due date
  /// (a reminder "1 day before at 09:00" stays "1 day before at 09:00").
  TaskItem rescheduled(DateTime? newDate, int? newMinutes, DateTime at) {
    var newReminderDate = reminderDate;
    final oldDue = dueDate;
    final oldReminder = reminderDate;
    if (newDate != null && oldDue != null && oldReminder != null) {
      newReminderDate = addDays(newDate, -daysBetween(oldReminder, oldDue));
    }
    return copyWith(
      dueDate: newDate,
      dueMinutes: newDate == null ? null : newMinutes,
      reminderDate: newReminderDate,
      updatedAt: at,
    );
  }

  /// The moment the reminder fires for the occurrence on [occurrenceDate], or
  /// null when no reminder is configured.
  ///
  /// With a due date, the reminder keeps its distance from it: a reminder set
  /// two days before the due date fires two days before EVERY occurrence.
  /// Without a due date it is a plain one-off date and time.
  DateTime? reminderFor(DateTime? occurrenceDate) {
    final day = reminderDate;
    final minutes = reminderMinutes;
    if (!reminderEnabled || day == null || minutes == null) return null;
    var base = day;
    final due = dueDate;
    if (due != null && occurrenceDate != null) {
      base = addDays(occurrenceDate, -daysBetween(day, due));
    }
    return atMinutes(base, minutes);
  }
}

/// A completed occurrence of a repeating task.
class OccurrenceCompletion {
  const OccurrenceCompletion({
    required this.taskId,
    required this.date,
    required this.completedAt,
  });

  final String taskId;
  final DateTime date;
  final DateTime completedAt;
}

/// Field-level validation. Returns a map of field -> message; empty means valid.
/// Keys: title, description, dueDate, dueTime, recurrence, reminder.
class TaskValidator {
  static const int maxTitleLength = 200;
  static const int maxDescriptionLength = 5000;

  static Map<String, String> validate(
    TaskItem task, {
    required DateTime now,
    bool checkReminderInPast = true,
  }) {
    final errors = <String, String>{};

    final title = task.title.trim();
    if (title.isEmpty) {
      errors['title'] = 'Enter a title.';
    } else if (title.length > maxTitleLength) {
      errors['title'] = 'Keep the title under $maxTitleLength characters.';
    }

    final description = task.description;
    if (description != null && description.length > maxDescriptionLength) {
      errors['description'] = 'Keep the description under $maxDescriptionLength characters.';
    }

    final due = task.dueDate;
    if (due != null && (due.year < 2000 || due.year > 2100)) {
      errors['dueDate'] = 'Choose a due date between the years 2000 and 2100.';
    }
    final minutes = task.dueMinutes;
    if (minutes != null) {
      if (due == null) {
        errors['dueTime'] = 'Pick a due date before setting a time.';
      } else if (minutes < 0 || minutes > 1439) {
        errors['dueTime'] = 'Time must be between 00:00 and 23:59.';
      }
    }

    final recurrenceError = task.recurrence.validate();
    if (recurrenceError != null) {
      errors['recurrence'] = recurrenceError;
    } else if (task.isRecurring && due == null) {
      errors['recurrence'] = 'A repeating task needs a start date.';
    }

    if (task.reminderEnabled) {
      final reminderDay = task.reminderDate;
      final reminderMinutes = task.reminderMinutes;
      if (reminderDay == null || reminderMinutes == null) {
        errors['reminder'] = 'Choose a reminder date and time.';
      } else if (reminderMinutes < 0 || reminderMinutes > 1439) {
        errors['reminder'] = 'Reminder time must be between 00:00 and 23:59.';
      } else if (due != null && reminderDay.isAfter(due)) {
        errors['reminder'] = 'The reminder must not be after the due date.';
      } else if (due != null &&
          minutes != null &&
          isSameDay(reminderDay, due) &&
          reminderMinutes > minutes) {
        errors['reminder'] = 'The reminder must not be after the due time.';
      } else if (checkReminderInPast && !task.isRecurring && task.status == TaskStatus.pending) {
        final at = task.reminderFor(due);
        if (at != null && !at.isAfter(now)) {
          errors['reminder'] = 'That reminder time has already passed.';
        }
      }
    }
    return errors;
  }
}
