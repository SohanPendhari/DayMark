import 'package:daymark/models/date_utils.dart';
import 'package:daymark/models/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('date helpers', () {
    test('formatDate pads and parseDate is its strict inverse', () {
      expect(formatDate(DateTime(2026, 3, 5)), '2026-03-05');
      expect(parseDate('2026-03-05'), DateTime(2026, 3, 5));
      expect(parseDate(formatDate(DateTime(2100, 12, 31))), DateTime(2100, 12, 31));
    });

    test('parseDate rejects malformed and impossible dates', () {
      expect(parseDate(null), isNull);
      expect(parseDate(''), isNull);
      expect(parseDate('2026-3-5'), isNull);
      expect(parseDate('2026-02-30'), isNull);
      expect(parseDate('2027-02-29'), isNull); // 2027 is not a leap year
      expect(parseDate('2028-02-29'), DateTime(2028, 2, 29));
      expect(parseDate('2026-13-01'), isNull);
      expect(parseDate('not a date'), isNull);
    });

    test('daysInMonth knows leap years, including the 2100 exception', () {
      expect(daysInMonth(2028, 2), 29);
      expect(daysInMonth(2027, 2), 28);
      expect(daysInMonth(2100, 2), 28);
      expect(daysInMonth(2026, 4), 30);
      expect(daysInMonth(2026, 12), 31);
    });

    test('addDays and daysBetween are calendar based, across month and year ends', () {
      expect(addDays(DateTime(2026, 12, 31), 1), DateTime(2027, 1, 1));
      expect(addDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
      expect(daysBetween(DateTime(2026, 3, 10), DateTime(2026, 3, 17)), 7);
      expect(daysBetween(DateTime(2026, 3, 17), DateTime(2026, 3, 10)), -7);
      expect(daysBetween(DateTime(2026, 3, 10, 23, 59), DateTime(2026, 3, 11, 0, 1)), 1);
    });

    test('describeDay uses relative words near today', () {
      final now = DateTime(2026, 3, 10, 15);
      expect(describeDay(DateTime(2026, 3, 10), now), 'Today');
      expect(describeDay(DateTime(2026, 3, 11), now), 'Tomorrow');
      expect(describeDay(DateTime(2026, 3, 9), now), 'Yesterday');
      expect(describeDay(DateTime(2026, 3, 13), now), 'Fri 13 Mar');
      expect(describeDay(DateTime(2027, 1, 4), now), 'Mon 4 Jan 2027');
    });

    test('formatMinutes and atMinutes', () {
      expect(formatMinutes(0), '00:00');
      expect(formatMinutes(9 * 60 + 5), '09:05');
      expect(formatMinutes(1439), '23:59');
      expect(atMinutes(DateTime(2026, 3, 10), 570), DateTime(2026, 3, 10, 9, 30));
    });
  });

  group('Recurrence', () {
    test('none never matches; daily always matches', () {
      expect(const Recurrence.none().matches(DateTime(2026, 3, 10)), isFalse);
      expect(const Recurrence.daily().matches(DateTime(2026, 3, 10)), isTrue);
    });

    test('weekly matches only the chosen weekdays', () {
      final rule = Recurrence.weekly(<int>{DateTime.monday, DateTime.friday});
      expect(rule.matches(DateTime(2026, 3, 9)), isTrue); // Monday
      expect(rule.matches(DateTime(2026, 3, 13)), isTrue); // Friday
      expect(rule.matches(DateTime(2026, 3, 10)), isFalse); // Tuesday
    });

    test('monthly clamps day 29-31 to the last day of short months', () {
      final rule = Recurrence.monthly(31);
      expect(rule.matches(DateTime(2026, 1, 31)), isTrue);
      expect(rule.matches(DateTime(2026, 2, 28)), isTrue);
      expect(rule.matches(DateTime(2026, 2, 27)), isFalse);
      expect(rule.matches(DateTime(2026, 4, 30)), isTrue);
      expect(rule.matches(DateTime(2026, 4, 29)), isFalse);
      expect(rule.matches(DateTime(2028, 2, 29)), isTrue); // leap year
      expect(rule.matches(DateTime(2028, 2, 28)), isFalse);
      // Never matches two days in one month.
      expect(rule.matches(DateTime(2026, 3, 30)), isFalse);
      expect(rule.matches(DateTime(2026, 3, 31)), isTrue);
    });

    test('monthly on a normal day is exact', () {
      final rule = Recurrence.monthly(15);
      expect(rule.matches(DateTime(2026, 2, 15)), isTrue);
      expect(rule.matches(DateTime(2026, 2, 14)), isFalse);
    });

    test('validate reports problems', () {
      expect(const Recurrence.none().validate(), isNull);
      expect(const Recurrence.daily().validate(), isNull);
      expect(Recurrence.weekly(<int>{}).validate(), isNotNull);
      expect(Recurrence.weekly(<int>{0}).validate(), isNotNull);
      expect(Recurrence.weekly(<int>{8}).validate(), isNotNull);
      expect(Recurrence.weekly(<int>{1, 7}).validate(), isNull);
      expect(Recurrence.monthly(0).validate(), isNotNull);
      expect(Recurrence.monthly(32).validate(), isNotNull);
      expect(Recurrence.monthly(31).validate(), isNull);
    });

    test('storage round trip keeps type, weekdays and day of month', () {
      final weekly = Recurrence.weekly(<int>{1, 3, 7});
      expect(weekly.weekdayMask, 0x45); // bits 0, 2, 6
      final restored = Recurrence.fromStorage(weekly.type.index, weekly.weekdayMask, null);
      expect(restored, weekly);
      final monthly = Recurrence.monthly(29);
      expect(Recurrence.fromStorage(monthly.type.index, 0, 29), monthly);
      expect(Recurrence.fromStorage(RecurrenceType.daily.index, 0, null), const Recurrence.daily());
    });

    test('fromStorage tolerates corrupt values', () {
      expect(Recurrence.fromStorage(99, 0, null).isRecurring, isFalse);
      expect(Recurrence.fromStorage(-1, 0, null).isRecurring, isFalse);
      expect(Recurrence.fromStorage(RecurrenceType.monthly.index, 0, null).dayOfMonth, 1);
    });

    test('describe is readable', () {
      expect(const Recurrence.daily().describe(), 'Every day');
      expect(Recurrence.weekly(<int>{5, 1}).describe(), 'Weekly on Mon, Fri');
      expect(Recurrence.monthly(10).describe(), 'Monthly on day 10');
      expect(Recurrence.monthly(31).describe(), contains('last day'));
    });
  });
}
