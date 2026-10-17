import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../models/date_utils.dart';
import '../../models/task_item.dart';
import '../../models/task_occurrence.dart';

void showMessage(ScaffoldMessengerState messenger, String message) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Completes or reopens one occurrence and reports any failure.
Future<void> toggleCompleted(BuildContext context, TaskOccurrence occurrence, bool completed) async {
  final controller = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final error = await controller.setCompleted(occurrence, completed);
  if (error != null) showMessage(messenger, error);
}

/// Asks for confirmation, then deletes the task. Returns true if it was deleted.
Future<bool> confirmDelete(BuildContext context, TaskItem task) async {
  final controller = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Delete task?'),
      content: Text(
        task.isRecurring
            ? '"${task.title}" repeats. Deleting it removes the whole series and its completion history.'
            : '"${task.title}" will be deleted.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  final error = await controller.deleteTask(task.id);
  if (error != null) {
    showMessage(messenger, error);
    return false;
  }
  showMessage(messenger, 'Task deleted');
  return true;
}

Future<void> rescheduleToTomorrow(BuildContext context, TaskItem task) async {
  final controller = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final tomorrow = addDays(dateOnly(controller.currentTime()), 1);
  final error = await controller.reschedule(task, tomorrow, task.dueMinutes);
  if (error != null) showMessage(messenger, error);
}

Future<void> rescheduleToPickedDate(BuildContext context, TaskItem task) async {
  final controller = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final today = dateOnly(controller.currentTime());
  final initial = task.dueDate ?? today;
  final picked = await showDatePicker(
    context: context,
    initialDate: initial.year < 2000 ? today : initial,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100, 12, 31),
    helpText: 'Reschedule',
  );
  if (picked == null) return;
  final error = await controller.reschedule(task, picked, task.dueMinutes);
  if (error != null) showMessage(messenger, error);
}
