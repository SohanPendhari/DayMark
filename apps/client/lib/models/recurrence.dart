import 'date_utils.dart';

enum RecurrenceType { none, daily, weekly, monthly }

/// How a task repeats.
///
/// * daily   - every day from the start date.
/// * weekly  - on the chosen weekdays (1 = Monday ... 7 = Sunday), every week.
/// * monthly - on one day of the month.
///
/// MONTH-END RULE: a monthly rule for day 29, 30 or 31 runs on the LAST day of
/// any month that is too short. "Monthly on the 31st" therefore gives
/// Jan 31, Feb 28 (29 in a leap year), Mar 31, Apr 30, ... Every month is
/// computed from the rule itself, never from the previous occurrence, so there
/// is no drift (Jan 31 -> Feb 28 -> Mar 31, not Mar 28).
class Recurrence {
  const Recurrence._(this.type, this.weekdays, this.dayOfMonth);

  const Recurrence.none() : this._(RecurrenceType.none, const <int>{}, null);

  const Recurrence.daily() : this._(RecurrenceType.daily, const <int>{}, null);

  const Recurrence.monthly(int dayOfMonth)
      : this._(RecurrenceType.monthly, const <int>{}, dayOfMonth);

  factory Recurrence.weekly(Iterable<int> weekdays) =>
      Recurrence._(RecurrenceType.weekly, Set<int>.unmodifiable(weekdays), null);

  /// Rebuilds a rule from its stored form (see [weekdayMask]).
  factory Recurrence.fromStorage(int typeIndex, int weekdayMask, int? dayOfMonth) {
    final type = (typeIndex >= 0 && typeIndex < RecurrenceType.values.length)
        ? RecurrenceType.values[typeIndex]
        : RecurrenceType.none;
    switch (type) {
      case RecurrenceType.none:
        return const Recurrence.none();
      case RecurrenceType.daily:
        return const Recurrence.daily();
      case RecurrenceType.weekly:
        return Recurrence.weekly(weekdaysFromMask(weekdayMask));
      case RecurrenceType.monthly:
        return Recurrence.monthly(dayOfMonth ?? 1);
    }
  }

  final RecurrenceType type;
  final Set<int> weekdays;
  final int? dayOfMonth;

  bool get isRecurring => type != RecurrenceType.none;

  /// Bit 0 = Monday ... bit 6 = Sunday.
  int get weekdayMask {
    var mask = 0;
    for (final day in weekdays) {
      if (day >= 1 && day <= 7) mask |= 1 << (day - 1);
    }
    return mask;
  }

  static Set<int> weekdaysFromMask(int mask) {
    final days = <int>{};
    for (var day = 1; day <= 7; day++) {
      if (mask & (1 << (day - 1)) != 0) days.add(day);
    }
    return days;
  }

  /// Returns a user-facing problem, or null when the rule is valid.
  String? validate() {
    switch (type) {
      case RecurrenceType.none:
      case RecurrenceType.daily:
        return null;
      case RecurrenceType.weekly:
        if (weekdays.isEmpty) return 'Choose at least one weekday.';
        for (final day in weekdays) {
          if (day < 1 || day > 7) return 'Weekdays must be Monday to Sunday.';
        }
        return null;
      case RecurrenceType.monthly:
        final day = dayOfMonth;
        if (day == null || day < 1 || day > 31) {
          return 'Choose a day of the month between 1 and 31.';
        }
        return null;
    }
  }

  /// Does this rule produce an occurrence on [date] (a calendar date)?
  /// The task's start date is applied by the caller.
  bool matches(DateTime date) {
    switch (type) {
      case RecurrenceType.none:
        return false;
      case RecurrenceType.daily:
        return true;
      case RecurrenceType.weekly:
        return weekdays.contains(date.weekday);
      case RecurrenceType.monthly:
        final wanted = dayOfMonth;
        if (wanted == null) return false;
        final last = daysInMonth(date.year, date.month);
        return date.day == (wanted > last ? last : wanted);
    }
  }

  String describe() {
    switch (type) {
      case RecurrenceType.none:
        return 'Does not repeat';
      case RecurrenceType.daily:
        return 'Every day';
      case RecurrenceType.weekly:
        final days = weekdays.toList()..sort();
        if (days.length == 7) return 'Every day';
        return 'Weekly on ${days.map((d) => kWeekdayShort[d - 1]).join(', ')}';
      case RecurrenceType.monthly:
        final day = dayOfMonth ?? 1;
        return day >= 29
            ? 'Monthly on day $day (last day in shorter months)'
            : 'Monthly on day $day';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Recurrence &&
      other.type == type &&
      other.dayOfMonth == dayOfMonth &&
      other.weekdayMask == weekdayMask;

  @override
  int get hashCode => Object.hash(type, dayOfMonth, weekdayMask);

  @override
  String toString() => 'Recurrence(${describe()})';
}
