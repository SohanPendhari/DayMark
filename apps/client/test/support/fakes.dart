import 'dart:async';

import 'package:daymark/models/recurrence.dart';
import 'package:daymark/models/task_item.dart';
import 'package:daymark/models/task_priority.dart';
import 'package:daymark/services/notification_gateway.dart';
import 'package:daymark/services/reminder_planner.dart';

/// Records what the reminder service asks the platform to do.
class FakeNotificationGateway implements NotificationGateway {
  FakeNotificationGateway({
    this.permission = NotificationPermissionStatus.notDetermined,
    this.grantOnRequest = true,
    this.background = true,
  });

  NotificationPermissionStatus permission;

  /// What a permission prompt results in.
  bool grantOnRequest;
  bool background;

  int initializeCount = 0;
  int requestCount = 0;
  int cancelCount = 0;
  final List<List<PlannedReminder>> scheduled = <List<PlannedReminder>>[];
  final StreamController<PlannedReminder> _fired = StreamController<PlannedReminder>.broadcast();

  List<PlannedReminder> get lastScheduled =>
      scheduled.isEmpty ? const <PlannedReminder>[] : scheduled.last;

  @override
  bool get deliversWhileClosed => background;

  @override
  Stream<PlannedReminder> get fired => _fired.stream;

  void fire(PlannedReminder reminder) => _fired.add(reminder);

  @override
  Future<void> initialize() async => initializeCount++;

  @override
  Future<NotificationPermissionStatus> permissionStatus() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    requestCount++;
    permission =
        grantOnRequest ? NotificationPermissionStatus.granted : NotificationPermissionStatus.denied;
    return permission;
  }

  @override
  Future<void> replaceAll(List<PlannedReminder> reminders) async {
    scheduled.add(List<PlannedReminder>.of(reminders));
  }

  @override
  Future<void> cancelAll() async => cancelCount++;

  @override
  Future<void> dispose() async {
    await _fired.close();
  }
}

/// Fixed "now" used across tests: Tuesday 10 March 2026, 10:00.
final DateTime kNow = DateTime(2026, 3, 10, 10);

TaskItem makeTask({
  String id = 't1',
  String title = 'Task',
  DateTime? due,
  int? minutes,
  TaskPriority priority = TaskPriority.medium,
  Recurrence recurrence = const Recurrence.none(),
  TaskStatus status = TaskStatus.pending,
  DateTime? completedAt,
  bool reminder = false,
  DateTime? reminderDate,
  int? reminderMinutes,
  DateTime? createdAt,
}) {
  final created = createdAt ?? DateTime(2026, 1, 1);
  return TaskItem(
    id: id,
    title: title,
    createdAt: created,
    updatedAt: created,
    dueDate: due,
    dueMinutes: minutes,
    priority: priority,
    status: status,
    completedAt: completedAt,
    reminderEnabled: reminder,
    reminderDate: reminderDate,
    reminderMinutes: reminderMinutes,
    recurrence: recurrence,
  );
}
