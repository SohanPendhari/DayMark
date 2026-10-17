import 'package:daymark/app/app_controller.dart';
import 'package:daymark/data/database/app_database.dart';
import 'package:daymark/data/settings_repository.dart';
import 'package:daymark/data/storage_info.dart';
import 'package:daymark/data/task_repository.dart';
import 'package:daymark/services/reminder_service.dart';
import 'package:daymark/services/sync_status.dart';
import 'package:drift/native.dart';

import 'fakes.dart';

/// A fully wired controller on an in-memory database (or the given one), a fake
/// notification gateway, and a controllable clock. Already initialised.
Future<AppController> makeController({
  AppDatabase? database,
  FakeNotificationGateway? gateway,
  DateTime Function()? clock,
}) async {
  final db = database ?? AppDatabase(NativeDatabase.memory());
  final time = clock ?? () => kNow;
  final controller = AppController(
    tasks: TaskRepository(db),
    settings: SettingsRepository(db),
    reminders: ReminderService(gateway ?? FakeNotificationGateway(), clock: time, refreshInterval: Duration.zero),
    sync: SyncStateMachine(),
    storage: StorageInfo(),
    database: db,
    clock: time,
    enableClockTick: false,
  );
  await controller.init();
  return controller;
}
