import 'package:daymark/app/app_controller.dart';
import 'package:daymark/app/daymark_app.dart';
import 'package:daymark/core/theme/daymark_theme.dart';
import 'package:daymark/core/theme/daymark_tokens.dart';
import 'package:daymark/features/tasks/tasks_home.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../support/test_app.dart';

/// Starts the real app on an in-memory database at the given window size.
Future<AppController> boot(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
  FakeNotificationGateway? gateway,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = (await tester.runAsync(() => makeController(gateway: gateway)))!;
  addTearDown(controller.dispose);
  await tester.pumpWidget(DayMarkApp(controller: controller));
  await tester.pump();
  return controller;
}

/// Lets real asynchronous database work finish, then rebuilds the UI.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Color dotColor(WidgetTester tester) {
  final dot = tester.widget<Container>(find.byKey(const ValueKey<String>('sync-dot')));
  return (dot.decoration! as BoxDecoration).color!;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const localOnlyTip = 'Local only: backend sync is not set up. Your tasks are saved on this device.';

  group('responsive layout', () {
    testWidgets('desktop width: sidebar, New task button and a labelled sync indicator', (tester) async {
      await boot(tester);
      expect(find.byKey(const ValueKey<String>('nav-today')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('nav-upcoming')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('nav-overdue')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('nav-completed')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('nav-all')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('new-task-button')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Local only'), findsOneWidget);
    });

    testWidgets('phone width: bottom navigation and a floating add button, no sidebar', (tester) async {
      await boot(tester, size: const Size(390, 844));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('nav-today')), findsNothing);
      expect(find.byTooltip(localOnlyTip), findsOneWidget);
    });

    testWidgets('the switch happens exactly at the breakpoint', (tester) async {
      await boot(tester, size: Size(kSidebarBreakpoint - 1, 900));
      expect(find.byType(NavigationBar), findsOneWidget);
      tester.view.physicalSize = Size(kSidebarBreakpoint, 900);
      await tester.pump();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey<String>('nav-today')), findsOneWidget);
    });
  });

  group('sync indicator', () {
    testWidgets('starts grey "Local only" with an explanatory tooltip', (tester) async {
      await boot(tester);
      expect(dotColor(tester), DaymarkTheme.light.colorScheme.onSurfaceVariant);
      expect(find.byTooltip(localOnlyTip), findsOneWidget);
    });

    testWidgets('stays grey even after local changes (nothing is claimed as synced)', (tester) async {
      final controller = await boot(tester);
      await tester.runAsync(() => controller.quickAdd('A task'));
      await tester.pump();
      expect(dotColor(tester), DaymarkTheme.light.colorScheme.onSurfaceVariant);
      expect(find.text('Local only'), findsOneWidget);
    });

    testWidgets('follows real state: red, yellow, green only after acknowledgment', (tester) async {
      final controller = await boot(tester);
      final scheme = DaymarkTheme.light.colorScheme;

      controller.sync.configureBackend(true); // a backend exists but has confirmed nothing
      await tester.pump();
      expect(dotColor(tester), scheme.error);
      expect(find.text('Offline'), findsOneWidget);

      controller.sync.syncStarted();
      await tester.pump();
      expect(dotColor(tester), DmColors.warningDark);
      expect(find.text('Syncing'), findsOneWidget);

      controller.sync.syncSucceeded(acknowledgedChanges: 0);
      await tester.pump();
      expect(dotColor(tester), DmSemanticColors.light.success);
      expect(find.text('Synced'), findsOneWidget);

      controller.sync.recordLocalChange(); // new unsynced work: back to red
      await tester.pump();
      expect(dotColor(tester), scheme.error);

      controller.sync.syncStarted();
      controller.sync.syncFailed('connection refused');
      await tester.pump();
      expect(dotColor(tester), scheme.error);
      expect(find.byTooltip('Sync failed: connection refused. 1 local change is waiting to sync.'), findsOneWidget);
    });
  });

  group('theme', () {
    testWidgets('the header toggle switches between light and dark', (tester) async {
      final controller = await boot(tester);
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
      await tester.tap(find.byTooltip('Switch to dark theme'));
      await settle(tester);
      expect(controller.themeMode.value, ThemeMode.dark);
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
      expect(find.byTooltip('Switch to light theme'), findsOneWidget);
      await tester.tap(find.byTooltip('Switch to light theme'));
      await settle(tester);
      expect(controller.themeMode.value, ThemeMode.light);
    });

    testWidgets('the sync dot is still grey in dark mode', (tester) async {
      final controller = await boot(tester);
      await tester.runAsync(() => controller.setThemeMode(ThemeMode.dark));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(dotColor(tester), DaymarkTheme.dark.colorScheme.onSurfaceVariant);
    });
  });

  group('tasks', () {
    testWidgets('an empty Today shows a friendly empty state', (tester) async {
      await boot(tester);
      expect(find.text('Nothing due today'), findsOneWidget);
      expect(find.text('0 / 0'), findsOneWidget);
    });

    testWidgets('quick add creates a task due today and updates the progress card', (tester) async {
      final controller = await boot(tester);
      await tester.enterText(find.byKey(const ValueKey<String>('quick-add')), 'Buy milk');
      await tester.tap(find.byKey(const ValueKey<String>('quick-add-button')));
      await settle(tester);
      expect(find.text('Buy milk'), findsOneWidget);
      expect(find.text('0 / 1'), findsOneWidget);
      expect(controller.views.today.length, 1);
    });

    testWidgets('quick add rejects an empty title', (tester) async {
      final controller = await boot(tester);
      await tester.tap(find.byKey(const ValueKey<String>('quick-add-button')));
      await tester.pump();
      expect(find.text('Enter a title.'), findsOneWidget);
      expect(controller.taskList, isEmpty);
    });

    testWidgets('the task form validates, then saves', (tester) async {
      final controller = await boot(tester);
      await tester.tap(find.byKey(const ValueKey<String>('new-task-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('save-task')));
      await tester.pump();
      expect(find.text('Enter a title.'), findsOneWidget);
      expect(controller.taskList, isEmpty);

      await tester.enterText(find.byKey(const ValueKey<String>('task-title')), 'Write report');
      await tester.tap(find.byKey(const ValueKey<String>('save-task')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(controller.taskList.single.title, 'Write report');
      expect(find.text('Write report'), findsOneWidget);
    });

    testWidgets('ticking the checkbox completes the task and updates progress', (tester) async {
      final controller = await boot(tester);
      await tester.runAsync(() => controller.quickAdd('Stretch'));
      await tester.pump();
      expect(find.text('0 / 1'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await settle(tester);
      expect(find.text('1 / 1'), findsOneWidget);
      expect(controller.views.completed.length, 1);
    });

    testWidgets('Overdue lists late tasks with a label; undated tasks only appear under All', (tester) async {
      final controller = await boot(tester);
      await tester.runAsync(() async {
        await controller.saveTask(makeTask(id: 'late', title: 'File taxes', due: DateTime(2026, 3, 9)));
        await controller.saveTask(makeTask(id: 'nodate', title: 'Someday'));
      });
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey<String>('nav-overdue')));
      await tester.pump();
      expect(find.text('File taxes'), findsOneWidget);
      expect(find.text('Overdue · 1 day'), findsOneWidget);
      expect(find.text('Someday'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('nav-all')));
      await tester.pump();
      expect(find.text('Someday'), findsOneWidget);
      expect(find.text('File taxes'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('nav-upcoming')));
      await tester.pump();
      expect(find.text('No upcoming tasks'), findsOneWidget);
    });

    testWidgets('on a phone, the bottom bar switches views', (tester) async {
      final controller = await boot(tester, size: const Size(390, 844));
      await tester.runAsync(() => controller.saveTask(makeTask(id: 'soon', title: 'Dentist', due: DateTime(2026, 3, 12))));
      await tester.pump();
      expect(find.text('Dentist'), findsNothing); // not due today
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Upcoming')));
      await tester.pump();
      expect(find.text('Dentist'), findsOneWidget);
    });
  });

  group('settings', () {
    testWidgets('turning notifications on asks for permission, once, from the switch', (tester) async {
      final gateway = FakeNotificationGateway();
      final controller = await boot(tester, gateway: gateway);
      await tester.tap(find.byKey(const ValueKey<String>('nav-settings')));
      await tester.pumpAndSettle();
      expect(gateway.requestCount, 0); // opening settings never prompts
      expect(find.text('Off'), findsOneWidget);
      expect(find.textContaining('Browsers cannot'), findsNothing); // the fake reports background delivery

      await tester.tap(find.byKey(const ValueKey<String>('notifications-switch')));
      await settle(tester);
      expect(gateway.requestCount, 1);
      expect(controller.reminders.isActive, isTrue);
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('a refused permission leaves it off and says so', (tester) async {
      final gateway = FakeNotificationGateway(grantOnRequest: false);
      await boot(tester, gateway: gateway);
      await tester.tap(find.byKey(const ValueKey<String>('nav-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('notifications-switch')));
      await settle(tester);
      expect(gateway.requestCount, 1);
      expect(find.textContaining('Blocked'), findsOneWidget);
      expect(find.text('Notifications were not allowed.'), findsOneWidget);
    });

    testWidgets('the web limitation is stated when delivery needs the tab open', (tester) async {
      final gateway = FakeNotificationGateway(background: false);
      await boot(tester, gateway: gateway);
      await tester.tap(find.byKey(const ValueKey<String>('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.textContaining('only while DAYMARK is open'), findsOneWidget);
    });

    testWidgets('settings show Local only sync and the storage description', (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const ValueKey<String>('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.textContaining('There is no backend yet'), findsOneWidget);
      expect(find.textContaining('stored on this device'), findsOneWidget);
    });
  });
}
