import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_scope.dart';
import '../../core/theme/daymark_tokens.dart';
import '../../models/date_utils.dart';
import '../../services/notification_gateway.dart';
import '../../shared/widgets/sync_status_indicator.dart';
import '../tasks/task_actions.dart';

const String kAppVersion = '0.1.0';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(DmSpace.x3),
            children: <Widget>[
              _Section(title: 'Appearance', child: _ThemeChooser(controller: controller)),
              const SizedBox(height: DmSpace.x2),
              _Section(title: 'Notifications', child: _NotificationSettings(controller: controller)),
              const SizedBox(height: DmSpace.x2),
              _Section(title: 'Storage', child: _StorageSettings(controller: controller)),
              const SizedBox(height: DmSpace.x2),
              _Section(title: 'Sync', child: _SyncSettings(controller: controller)),
              const SizedBox(height: DmSpace.x2),
              const _Section(
                title: 'About',
                child: Text('DAYMARK $kAppVersion\nPlan your day. Track your progress.'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(DmSpace.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: DmSpace.x1_5),
            child,
          ],
        ),
      ),
    );
  }
}

class _ThemeChooser extends StatelessWidget {
  const _ThemeChooser({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: controller.themeMode,
      builder: (BuildContext context, ThemeMode mode, Widget? _) {
        return SegmentedButton<ThemeMode>(
          segments: const <ButtonSegment<ThemeMode>>[
            ButtonSegment<ThemeMode>(
              value: ThemeMode.system,
              label: Text('System'),
              icon: Icon(Icons.brightness_auto_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.light,
              label: Text('Light'),
              icon: Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.dark,
              label: Text('Dark'),
              icon: Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: <ThemeMode>{mode},
          onSelectionChanged: (Set<ThemeMode> value) => controller.setThemeMode(value.first),
        );
      },
    );
  }
}

class _NotificationSettings extends StatelessWidget {
  const _NotificationSettings({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reminders = controller.reminders;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    String status() {
      switch (reminders.permission) {
        case NotificationPermissionStatus.unsupported:
          return 'Not available on this device or browser.';
        case NotificationPermissionStatus.denied:
          return 'Blocked. Allow notifications in your browser or phone settings, then turn this on again.';
        case NotificationPermissionStatus.granted:
        case NotificationPermissionStatus.notDetermined:
          return reminders.isActive ? 'On' : 'Off';
      }
    }

    final next = reminders.planned.isEmpty ? null : reminders.planned.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          key: const ValueKey<String>('notifications-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Task reminders'),
          subtitle: Text(status()),
          value: reminders.isActive,
          onChanged: (bool on) async {
            final messenger = ScaffoldMessenger.of(context);
            final result = await controller.setNotificationsEnabled(on);
            if (on && result != NotificationPermissionStatus.granted) {
              showMessage(messenger, 'Notifications were not allowed.');
            }
          },
        ),
        const SizedBox(height: DmSpace.x1),
        Text(
          reminders.deliversWhileClosed
              ? 'Reminders are scheduled with Android and are delivered even when DAYMARK is closed. Android may deliver them a few minutes late.'
              : 'Browsers cannot schedule notifications. Reminders appear only while DAYMARK is open in a browser tab. Nothing is delivered after you close the tab or Chrome, and background tabs may delay them.',
          style: muted,
        ),
        const SizedBox(height: DmSpace.x1),
        Text(
          reminders.isActive
              ? '${reminders.planned.length} upcoming reminder${reminders.planned.length == 1 ? '' : 's'} planned'
                  '${next == null ? '' : '. Next: ${next.title}, ${describeDay(dateOnly(next.at), controller.now)} ${formatMinutes(next.at.hour * 60 + next.at.minute)}'}.'
              : 'No reminders are planned while notifications are off.',
          style: muted,
        ),
        if (reminders.lastError != null) ...<Widget>[
          const SizedBox(height: DmSpace.x1),
          Text(
            'Scheduling problem: ${reminders.lastError}',
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}

class _StorageSettings extends StatelessWidget {
  const _StorageSettings({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final storage = controller.storage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(storage.description, style: theme.textTheme.bodyMedium),
        const SizedBox(height: DmSpace.x0_5),
        Text(
          storage.isPersistent
              ? 'Your tasks are stored on this device and survive restarts and refreshes.'
              : 'Your tasks will be lost when this tab is refreshed.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: storage.isPersistent ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error,
          ),
        ),
      ],
    );
  }
}

class _SyncSettings extends StatelessWidget {
  const _SyncSettings({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller.sync,
      builder: (BuildContext context, Widget? _) {
        final snapshot = controller.sync.snapshot;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Align(alignment: Alignment.centerLeft, child: SyncStatusIndicator(showLabel: true)),
            const SizedBox(height: DmSpace.x0_5),
            Text(snapshot.description, style: theme.textTheme.bodyMedium),
            if (!controller.sync.backendConfigured) ...<Widget>[
              const SizedBox(height: DmSpace.x0_5),
              Text(
                'There is no backend yet. All changes stay on this device until sync is added.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        );
      },
    );
  }
}
