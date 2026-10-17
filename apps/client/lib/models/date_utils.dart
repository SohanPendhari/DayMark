// Calendar helpers.
//
// Every "date" in DAYMARK is a LOCAL calendar date held as a DateTime at local
// midnight. Dates are never stored as UTC instants, so a task due on "5 March"
// stays on 5 March when the user travels or daylight saving changes.

const List<String> kWeekdayShort = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> kWeekdayLong = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const List<String> kMonthShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Adds whole calendar days. Uses the DateTime constructor (not Duration) so
/// it is correct across daylight-saving changes.
DateTime addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Whole calendar days from [from] to [to] (negative when [to] is earlier).
int daysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');

/// `yyyy-MM-dd`. This is the storage format for dates.
String formatDate(DateTime d) => '${_pad(d.year, 4)}-${_pad(d.month, 2)}-${_pad(d.day, 2)}';

final RegExp _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Strict inverse of [formatDate]. Returns null for null, malformed, or
/// impossible dates such as `2026-02-30`.
DateTime? parseDate(String? text) {
  if (text == null) return null;
  final match = _isoDate.firstMatch(text);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final parsed = DateTime(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

/// 24-hour `HH:mm` for minutes since midnight.
String formatMinutes(int minutes) => '${_pad(minutes ~/ 60, 2)}:${_pad(minutes % 60, 2)}';

/// Local date-time at [minutes] after midnight on [date].
DateTime atMinutes(DateTime date, int minutes) =>
    DateTime(date.year, date.month, date.day, minutes ~/ 60, minutes % 60);

/// "Today", "Tomorrow", "Yesterday", otherwise "Thu 5 Mar" (year added when it
/// differs from [now]'s year).
String describeDay(DateTime date, DateTime now) {
  final diff = daysBetween(dateOnly(now), date);
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  final base =
      '${kWeekdayShort[date.weekday - 1]} ${date.day} ${kMonthShort[date.month - 1]}';
  return date.year == now.year ? base : '$base ${date.year}';
}
