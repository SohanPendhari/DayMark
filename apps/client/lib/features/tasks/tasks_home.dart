
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_scope.dart';
import '../../core/theme/daymark_theme.dart';
import '../../core/theme/daymark_tokens.dart';
import '../../models/task_views.dart';
import '../../shared/widgets/daymark_logo.dart';
import '../../shared/widgets/sync_status_indicator.dart';
import '../../shared/widgets/theme_toggle_button.dart';
import '../settings/settings_screen.dart';
import 'task_actions.dart';
import 'task_details.dart';
import 'task_form.dart';
import 'task_list_pane.dart';

/// At and above this width the sidebar layout is used; below it, the compact
/// phone layout with bottom navigation.
const double kSidebarBreakpoint = 840;

class TasksHome extends StatefulWidget {
  const TasksHome({super.key});

  @override
  State<TasksHome> createState() => _TasksHomeState();
}

class _TasksHomeState extends State<TasksHome> {
  AppController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final controller = AppScope.read(context);

    if (!identical(controller, _controller)) {
      _detach();
      _controller = controller;

      controller.lastFiredReminder.addListener(_onReminderFired);
      controller.focusedOccurrence.addListener(_onNotificationTapped);
    }
  }

  void _detach() {
    _controller?.lastFiredReminder.removeListener(_onReminderFired);
    _controller?.focusedOccurrence.removeListener(_onNotificationTapped);
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _onReminderFired() {
    final reminder = _controller?.lastFiredReminder.value;

    if (reminder == null || !mounted) return;

    showMessage(
      ScaffoldMessenger.of(context),
      'Reminder: ${reminder.title} · ${reminder.body}',
    );
  }

  void _onNotificationTapped() {
    final controller = _controller;
    final occurrence = controller?.focusedOccurrence.value;

    if (controller == null || occurrence == null || !mounted) return;

    controller.focusedOccurrence.value = null;
    showTaskDetails(context, occurrence);
  }

  void _newTask(AppController controller) {
    showTaskForm(
      context,
      initialDate:
          controller.tab == TaskTab.today ? controller.now : null,
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);

    if (controller.loading) {
      return Scaffold(
        body: Center(
          child: Semantics(
            label: 'Loading your tasks',
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }

    if (controller.initError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(DmSpace.x3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: 40,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: DmSpace.x2),
                Text(
                  controller.initError!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: DmSpace.x2),
                FilledButton(
                  onPressed: controller.init,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final wide = constraints.maxWidth >= kSidebarBreakpoint;

        return wide
            ? _buildWide(context, controller)
            : _buildCompact(context, controller);
      },
    );
  }

  // ---- Phone / narrow window -----------------------------------------------

  Widget _buildCompact(
    BuildContext context,
    AppController controller,
  ) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Align(
          alignment: Alignment.centerLeft,
          child: DaymarkLogo(height: 28),
        ),
        actions: <Widget>[
          const SyncStatusIndicator(),
          const ThemeToggleButton(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: TaskListPane(tab: controller.tab),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New task',
        onPressed: () => _newTask(controller),
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: controller.tab.index,
        onDestinationSelected: (int index) {
          controller.tab = TaskTab.values[index];
        },
        destinations: <Widget>[
          for (final tab in TaskTab.values)
            NavigationDestination(
              icon: _badged(controller, tab, scheme),
              label: kTabTitles[tab]!,
            ),
        ],
      ),
    );
  }

  Widget _badged(
    AppController controller,
    TaskTab tab,
    ColorScheme scheme,
  ) {
    final count = controller.views.countFor(tab);

    return Badge(
      isLabelVisible:
          count > 0 && tab != TaskTab.completed && tab != TaskTab.all,
      label: Text('$count'),
      backgroundColor: tab == TaskTab.overdue ? scheme.error : null,
      child: Icon(kTabIcons[tab]),
    );
  }

  // ---- Desktop / wide window -----------------------------------------------

  Widget _buildWide(
    BuildContext context,
    AppController controller,
  ) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          _Sidebar(onOpenSettings: _openSettings),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DmSpace.x3,
                    vertical: DmSpace.x1,
                  ),
                  child: Row(
                    children: <Widget>[
                      const Spacer(),
                      const SyncStatusIndicator(showLabel: true),
                      const SizedBox(width: DmSpace.x0_5),
                      const ThemeToggleButton(),
                      const SizedBox(width: DmSpace.x1),
                      FilledButton.icon(
                        key: const ValueKey<String>('new-task-button'),
                        onPressed: () => _newTask(controller),
                        icon: const Icon(Icons.add),
                        label: const Text('New task'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: TaskListPane(tab: controller.tab),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selectedColor = context.dm.gold.withValues(alpha: 0.22);

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(DmRadius.md),
    );

    return SizedBox(
      width: DmSize.sidebarExpanded,
      child: Material(
        color: scheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(
                DmSpace.x2,
                DmSpace.x3,
                DmSpace.x2,
                DmSpace.x2,
              ),
              child: DaymarkLogo(height: 30),
            ),
            for (final tab in TaskTab.values)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DmSpace.x1,
                  vertical: 2,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: ListTile(
                    key: ValueKey<String>('nav-${tab.name}'),
                    shape: shape,
                    selected: controller.tab == tab,
                    selectedTileColor: selectedColor,
                    selectedColor: scheme.onSurface,
                    leading: Icon(kTabIcons[tab]),
                    title: Text(kTabTitles[tab]!),
                    trailing: _Count(
                      count: controller.views.countFor(tab),
                      visible: tab != TaskTab.completed &&
                          tab != TaskTab.all,
                      alert: tab == TaskTab.overdue,
                    ),
                    onTap: () => controller.tab = tab,
                  ),
                ),
              ),
            const Spacer(),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(DmSpace.x1),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  key: const ValueKey<String>('nav-settings'),
                  shape: shape,
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  onTap: onOpenSettings,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({
    required this.count,
    required this.visible,
    required this.alert,
  });

  final int count;
  final bool visible;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    if (!visible || count == 0) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;

    return Text(
      '$count',
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: alert ? scheme.error : scheme.onSurfaceVariant,
            fontFeatures: const <FontFeature>[
              FontFeature.tabularFigures(),
            ],
          ),
    );
  }
}
