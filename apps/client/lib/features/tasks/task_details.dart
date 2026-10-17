import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/daymark_tokens.dart';
import '../../models/date_utils.dart';
import '../../models/task_occurrence.dart';
import '../../shared/format.dart';
import 'task_actions.dart';
import 'task_form.dart';

/// Read-only view of a task with the main actions.
Future<void> showTaskDetails(BuildContext context, TaskOccurrence occurrence) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => _TaskDetailsDialog(occurrence: occurrence),
  );
}

class _TaskDetailsDialog extends StatelessWidget {
  const _TaskDetailsDialog({required this.occurrence});

  final TaskOccurrence occurrence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context);
    final now = controller.now;
    final task = occurrence.task;
    final overdue = occurrence.overdueLabel(now);

    String reminderText() {
      if (!task.reminderEnabled) return 'Off';
      final at = task.reminderFor(occurrence.date);
      if (at == null) return 'On';
      final minutes = at.hour * 60 + at.minute;
      return '${describeDay(dateOnly(at), now)} · ${formatTimeOfDay(context, minutes)}';
    }

    final rows = <MapEntry<String, String>>[
      MapEntry<String, String>(
        'Status',
        occurrence.isCompleted ? 'Completed' : (overdue ?? 'Pending'),
      ),
      MapEntry<String, String>('Due', dueText(context, occurrence, now)),
      MapEntry<String, String>('Priority', task.priority.label),
      MapEntry<String, String>('Repeats', task.recurrence.describe()),
      MapEntry<String, String>('Reminder', reminderText()),
      if (occurrence.completedAt != null)
        MapEntry<String, String>('Completed', describeDay(occurrence.completedAt!, now)),
      MapEntry<String, String>('Created', describeDay(task.createdAt, now)),
    ];

    return AlertDialog(
      title: Text(task.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: DmSpace.x1),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 92,
                        child: Text(
                          row.key,
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Expanded(child: Text(row.value, style: theme.textTheme.bodyMedium)),
                    ],
                  ),
                ),
              if ((task.description ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: DmSpace.x1),
                Text('Notes', style: theme.textTheme.labelMedium),
                const SizedBox(height: DmSpace.x0_5),
                Text(task.description!, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () async {
            // Use the Navigator's own context (it outlives this dialog) for anything
            // that happens after the dialog closes or while it is closing.
            final navigator = Navigator.of(context);
            final deleted = await confirmDelete(navigator.context, task);
            if (deleted && navigator.mounted) navigator.pop();
          },
          child: const Text('Delete'),
        ),
        TextButton(
          onPressed: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            showTaskForm(navigator.context, existing: task);
          },
          child: const Text('Edit'),
        ),
        FilledButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await toggleCompleted(navigator.context, occurrence, !occurrence.isCompleted);
            if (navigator.mounted) navigator.pop();
          },
          child: Text(occurrence.isCompleted ? 'Mark pending' : 'Complete'),
        ),
      ],
    );
  }
}
