import 'package:flutter/material.dart';

import '../models/date_utils.dart';
import '../models/task_occurrence.dart';

/// Time of day in the user's locale format (12h or 24h).
String formatTimeOfDay(BuildContext context, int minutes) =>
    TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);

/// "Today · 9:30 AM", "Thu 5 Mar", "No due date".
String dueText(BuildContext context, TaskOccurrence occurrence, DateTime now) {
  final date = occurrence.date;
  if (date == null) return 'No due date';
  final day = describeDay(date, now);
  final minutes = occurrence.dueMinutes;
  return minutes == null ? day : '$day · ${formatTimeOfDay(context, minutes)}';
}
