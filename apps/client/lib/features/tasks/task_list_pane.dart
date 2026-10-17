
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/daymark_tokens.dart';
import '../../models/date_utils.dart';
import '../../models/task_views.dart';
import '../../shared/widgets/empty_state.dart';
import 'task_form.dart';
import 'task_tile.dart';

const Map<TaskTab, String> kTabTitles = <TaskTab, String>{
  TaskTab.today: 'Today',
  TaskTab.upcoming: 'Upcoming',
  TaskTab.overdue: 'Overdue',
  TaskTab.completed: 'Completed',
  TaskTab.all: 'All tasks',
};

const Map<TaskTab, IconData> kTabIcons = <TaskTab, IconData>{
  TaskTab.today: Icons.today_outlined,
  TaskTab.upcoming: Icons.event_outlined,
  TaskTab.overdue: Icons.warning_amber_rounded,
  TaskTab.completed: Icons.check_circle_outline,
  TaskTab.all: Icons.list_alt_outlined,
};

/// The list for one tab, with the Today summary and quick-add above Today.
class TaskListPane extends StatelessWidget {
  const TaskListPane({super.key, required this.tab});

  final TaskTab tab;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    final views = controller.views;
    final items = views.forTab(tab);
    final now = controller.now;

    final header = <Widget>[
      if (tab == TaskTab.today) ...<Widget>[
        Text(
          _longDate(now),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: DmSpace.x0_5),
        Text(
          'Your day, in focus.',
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: DmSpace.x2),
        _GlanceCard(
          completed: views.todayCompleted,
          total: views.today.length,
          progress: views.todayProgress,
        ),
        const SizedBox(height: DmSpace.x2),
        const _QuickAdd(),
        const SizedBox(height: DmSpace.x2),
      ] else ...<Widget>[
        Text(
          kTabTitles[tab]!,
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: DmSpace.x0_5),
        Text(
          _subtitle(tab),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: DmSpace.x2),
      ],
      if (!controller.storage.isPersistent) ...<Widget>[
        _StorageWarning(text: controller.storage.description),
        const SizedBox(height: DmSpace.x2),
      ],
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: DmSize.contentMaxWidth,
        ),
        child: ListView(
          key: PageStorageKey<TaskTab>(tab),
          padding: const EdgeInsets.all(DmSpace.x3),
          children: <Widget>[
            ...header,
            if (items.isEmpty)
              _emptyFor(context, tab)
            else
              for (final occurrence in items)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: DmSpace.x1,
                  ),
                  child: TaskTile(
                    key: ValueKey<String>(
                      '${tab.name}:${occurrence.key}',
                    ),
                    occurrence: occurrence,
                    showCompletedDate: tab == TaskTab.completed,
                  ),
                ),
            const SizedBox(height: DmSpace.x8),
          ],
        ),
      ),
    );
  }

  static String _subtitle(TaskTab tab) {
    switch (tab) {
      case TaskTab.today:
        return '';
      case TaskTab.upcoming:
        return 'Everything due after today.';
      case TaskTab.overdue:
        return 'Unfinished tasks past their deadline.';
      case TaskTab.completed:
        return 'Your completed tasks, newest first.';
      case TaskTab.all:
        return 'Every task, including ones without a due date.';
    }
  }

  static String _longDate(DateTime d) =>
      '${kWeekdayLong[d.weekday - 1].toUpperCase()}, '
      '${d.day} ${kMonthShort[d.month - 1].toUpperCase()}';

  static Widget _emptyFor(BuildContext context, TaskTab tab) {
    switch (tab) {
      case TaskTab.today:
        return EmptyState(
          icon: Icons.wb_sunny_outlined,
          title: 'Nothing due today',
          message: 'Add a task above, or enjoy the free time.',
          action: FilledButton.icon(
            onPressed: () => showTaskForm(
              context,
              initialDate: AppScope.read(context).now,
            ),
            icon: const Icon(Icons.add),
            label: const Text('New task'),
          ),
        );
      case TaskTab.upcoming:
        return const EmptyState(
          icon: Icons.event_available_outlined,
          title: 'No upcoming tasks',
          message: 'Tasks with a future due date will appear here.',
        );
      case TaskTab.overdue:
        return const EmptyState(
          icon: Icons.verified_outlined,
          title: 'Nothing overdue',
          message: 'You are all caught up.',
        );
      case TaskTab.completed:
        return const EmptyState(
          icon: Icons.check_circle_outline,
          title: 'No completed tasks yet',
          message: 'Tasks you finish will be listed here.',
        );
      case TaskTab.all:
        return EmptyState(
          icon: Icons.inbox_outlined,
          title: 'No tasks yet',
          message: 'Create your first task to get started.',
          action: FilledButton.icon(
            onPressed: () => showTaskForm(context),
            icon: const Icon(Icons.add),
            label: const Text('New task'),
          ),
        );
    }
  }
}

class _GlanceCard extends StatelessWidget {
  const _GlanceCard({
    required this.completed,
    required this.total,
    required this.progress,
  });

  final int completed;
  final int total;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (progress * 100).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(DmSpace.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'TODAY AT A GLANCE',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: DmSpace.x1_5),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: DmSpace.x1,
              runSpacing: DmSpace.x0_5,
              children: <Widget>[
                Text(
                  '$completed / $total',
                  style: theme.textTheme.displaySmall,
                ),
                Text(
                  total == 0
                      ? 'no tasks today'
                      : 'tasks done · $percent%',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: DmSpace.x1_5),
            Semantics(
              label:
                  'Today progress: $completed of $total tasks completed',
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                borderRadius: BorderRadius.circular(DmRadius.full),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAdd extends StatefulWidget {
  const _QuickAdd();

  @override
  State<_QuickAdd> createState() => _QuickAddState();
}

class _QuickAddState extends State<_QuickAdd> {
  final TextEditingController _text = TextEditingController();

  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final controller = AppScope.read(context);
    final title = _text.text.trim();

    if (title.isEmpty) {
      setState(() => _error = 'Enter a title.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final error = await controller.quickAdd(title);

    if (!mounted) return;

    setState(() {
      _busy = false;
      _error = error;

      if (error == null) {
        _text.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            key: const ValueKey<String>('quick-add'),
            controller: _text,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              hintText: 'Add a task for today',
              prefixIcon: Icon(Icons.add),
            ).copyWith(errorText: _error),
          ),
        ),
        const SizedBox(width: DmSpace.x1),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: FilledButton(
            key: const ValueKey<String>('quick-add-button'),
            onPressed: _busy ? null : _submit,
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }
}

class _StorageWarning extends StatelessWidget {
  const _StorageWarning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DmRadius.md),
        border: Border.all(color: scheme.error),
      ),
      child: Padding(
        padding: const EdgeInsets.all(DmSpace.x1_5),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.warning_amber_rounded,
              color: scheme.error,
            ),
            const SizedBox(width: DmSpace.x1),
            Expanded(
              child: Text(
                'Your tasks are NOT being saved permanently. '
                '$text. They will be lost when this tab is refreshed. '
                'Try a normal (non-private) browser window.',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
