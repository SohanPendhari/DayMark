import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/daymark_theme.dart';
import '../../core/theme/daymark_tokens.dart';
import '../../models/date_utils.dart';
import '../../models/task_occurrence.dart';
import '../../models/task_priority.dart';
import '../../shared/format.dart';
import 'task_actions.dart';
import 'task_details.dart';
import 'task_form.dart';

enum _TileAction { edit, tomorrow, pickDate, delete }

/// One task occurrence as a compact card.
class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.occurrence, this.showCompletedDate = false});

  final TaskOccurrence occurrence;
  final bool showCompletedDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = AppScope.of(context);
    final now = controller.now;
    final task = occurrence.task;
    final done = occurrence.isCompleted;
    final overdue = occurrence.overdueLabel(now);
    final muted = scheme.onSurfaceVariant;

    final meta = <Widget>[
      _Meta(
        icon: Icons.event_outlined,
        text: dueText(context, occurrence, now),
        color: muted,
      ),
      if (overdue != null)
        _Meta(icon: Icons.warning_amber_rounded, text: overdue, color: scheme.error, bold: true),
      _Meta(
        icon: Icons.flag_outlined,
        text: '${task.priority.label} priority',
        color: _priorityColor(context, task.priority),
      ),
      if (task.isRecurring)
        _Meta(icon: Icons.repeat, text: task.recurrence.describe(), color: muted),
      if (task.reminderEnabled)
        _Meta(icon: Icons.notifications_outlined, text: 'Reminder', color: muted),
      if (showCompletedDate && occurrence.completedAt != null)
        _Meta(
          icon: Icons.check_circle_outline,
          text: 'Completed ${describeDay(occurrence.completedAt!, now)}',
          color: context.dm.success,
        ),
    ];

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(DmRadius.lg),
        onTap: () => showTaskDetails(context, occurrence),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(DmSpace.x0_5, DmSpace.x1, DmSpace.x0_5, DmSpace.x1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                label: done ? 'Mark ${task.title} as not completed' : 'Mark ${task.title} as completed',
                child: Checkbox(
                  value: done,
                  onChanged: (bool? value) => toggleCompleted(context, occurrence, value ?? false),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: DmSpace.x1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        task.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          decoration: done ? TextDecoration.lineThrough : null,
                          color: done ? muted : null,
                        ),
                      ),
                      const SizedBox(height: DmSpace.x0_5),
                      Wrap(spacing: DmSpace.x1_5, runSpacing: DmSpace.x0_5, children: meta),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<_TileAction>(
                tooltip: 'Task actions',
                onSelected: (_TileAction action) => _onAction(context, action),
                itemBuilder: (BuildContext context) => <PopupMenuEntry<_TileAction>>[
                  const PopupMenuItem<_TileAction>(value: _TileAction.edit, child: Text('Edit')),
                  if (!task.isRecurring) ...<PopupMenuEntry<_TileAction>>[
                    const PopupMenuItem<_TileAction>(
                      value: _TileAction.tomorrow,
                      child: Text('Move to tomorrow'),
                    ),
                    const PopupMenuItem<_TileAction>(
                      value: _TileAction.pickDate,
                      child: Text('Reschedule…'),
                    ),
                  ],
                  const PopupMenuItem<_TileAction>(value: _TileAction.delete, child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onAction(BuildContext context, _TileAction action) {
    final task = occurrence.task;
    switch (action) {
      case _TileAction.edit:
        showTaskForm(context, existing: task);
      case _TileAction.tomorrow:
        rescheduleToTomorrow(context, task);
      case _TileAction.pickDate:
        rescheduleToPickedDate(context, task);
      case _TileAction.delete:
        confirmDelete(context, task);
    }
  }

  static Color _priorityColor(BuildContext context, TaskPriority priority) {
    switch (priority) {
      case TaskPriority.high:
        return Theme.of(context).colorScheme.error;
      case TaskPriority.medium:
        return context.dm.goldText;
      case TaskPriority.low:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, required this.color, this.bold = false});

  final IconData icon;
  final String text;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: bold ? FontWeight.w700 : null,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: style)),
      ],
    );
  }
}
