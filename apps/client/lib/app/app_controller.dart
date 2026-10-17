import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database/app_database.dart';
import '../data/settings_repository.dart';
import '../data/storage_info.dart';
import '../data/task_repository.dart';
import '../models/date_utils.dart';
import '../models/ids.dart';
import '../models/task_item.dart';
import '../models/task_occurrence.dart';
import '../models/task_views.dart';
import '../services/local_notification_gateway.dart';
import '../services/notification_gateway.dart';
import '../services/occurrence_engine.dart';
import '../services/reminder_planner.dart';
import '../services/reminder_service.dart';
import '../services/sync_status.dart';

/// Application state and the only place that changes tasks.
///
/// Every mutation: writes to the local database -> records a local change for
/// the (future) sync -> reloads -> recomputes the views -> re-plans reminders.
/// Mutating methods return null on success or a user-facing error message.
class AppController extends ChangeNotifier {
  AppController({
    required TaskRepository tasks,
    required SettingsRepository settings,
    required this.reminders,
    required this.sync,
    required this.storage,
    AppDatabase? database,
    DateTime Function()? clock,
    bool enableClockTick = true,
  })  : _tasks = tasks,
        _settings = settings,
        _database = database,
        _clock = clock ?? DateTime.now,
        _enableClockTick = enableClockTick,
        _now = (clock ?? DateTime.now)();

  /// Production wiring: real database, platform notifications, local-only sync.
  factory AppController.production() {
    final storage = StorageInfo();
    final database = AppDatabase.open(onWebResult: storage.recordWebResult);
    late final AppController controller;
    final gateway = LocalNotificationGateway(
      onSelect: (String payload) => controller.handleNotificationTap(payload),
    );
    controller = AppController(
      tasks: TaskRepository(database),
      settings: SettingsRepository(database),
      reminders: ReminderService(gateway),
      sync: SyncStateMachine(), // backend not configured: stays Local only
      storage: storage,
      database: database,
    );
    return controller;
  }

  final TaskRepository _tasks;
  final SettingsRepository _settings;
  final AppDatabase? _database;
  final DateTime Function() _clock;
  final bool _enableClockTick;

  final ReminderService reminders;
  final SyncStateMachine sync;
  final StorageInfo storage;

  /// Theme is its own notifier so changing it rebuilds only MaterialApp.
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);

  /// Set when a reminder is delivered while the app is open (shown in-app too).
  final ValueNotifier<PlannedReminder?> lastFiredReminder = ValueNotifier<PlannedReminder?>(null);

  /// Set when the user taps a notification; the UI opens that task.
  final ValueNotifier<TaskOccurrence?> focusedOccurrence = ValueNotifier<TaskOccurrence?>(null);

  bool _loading = true;
  String? _initError;
  DateTime _now;
  List<TaskItem> _taskList = const <TaskItem>[];
  List<OccurrenceCompletion> _completions = const <OccurrenceCompletion>[];
  List<TaskOccurrence> _occurrences = const <TaskOccurrence>[];
  TaskViews _views = TaskViews.empty;
  TaskTab _tab = TaskTab.today;
  Timer? _tick;
  StreamSubscription<PlannedReminder>? _firedSub;
  bool _disposed = false;

  bool get loading => _loading;
  String? get initError => _initError;
  DateTime get now => _now;
  TaskViews get views => _views;
  List<TaskOccurrence> get occurrences => _occurrences;
  List<TaskItem> get taskList => _taskList;
  TaskTab get tab => _tab;

  set tab(TaskTab value) {
    if (_tab == value) return;
    _tab = value;
    notifyListeners();
  }

  DateTime currentTime() => _clock();

  // ---- start-up ----------------------------------------------------------

  Future<void> init() async {
    _loading = true;
    _initError = null;
    notifyListeners();
    try {
      themeMode.value = _parseTheme(await _settings.read(SettingsRepository.themeModeKey));
      final notificationsOn =
          await _settings.read(SettingsRepository.notificationsEnabledKey) == 'true';
      await reminders.initialize(enabled: notificationsOn);
      _firedSub ??= reminders.fired.listen((PlannedReminder r) => lastFiredReminder.value = r);
      await _reload();
      if (_enableClockTick) {
        _tick ??= Timer.periodic(const Duration(seconds: 30), (_) => _onTick());
      }
    } catch (error) {
      _initError = 'DAYMARK could not open its local database.\n$error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    _taskList = await _tasks.loadTasks();
    _completions = await _tasks.loadCompletions();
    _recompute();
    unawaited(reminders.update(_occurrences));
  }

  void _recompute() {
    _now = _clock();
    _occurrences = OccurrenceEngine.build(tasks: _taskList, completions: _completions, now: _now);
    _views = TaskViews.build(_occurrences, _now);
    if (!_disposed) notifyListeners();
  }

  /// Re-evaluates overdue/today against the current time. Called by the 30-second
  /// timer, and safe to call whenever the app returns to the foreground.
  void refreshTime() => _onTick();

  /// Time passes: tasks become overdue and "today" rolls over without any user action.
  void _onTick() {
    final previous = _now;
    final fresh = _clock();
    if (fresh.minute == previous.minute && isSameDay(fresh, previous)) return;
    _recompute();
    if (!isSameDay(fresh, previous)) unawaited(reminders.update(_occurrences));
  }

  // ---- task operations -----------------------------------------------------

  /// Creates a task with just a title, due today (the Today tab's quick add).
  Future<String?> quickAdd(String title) {
    final at = _clock();
    return saveTask(TaskItem(
      id: newId(),
      title: title,
      createdAt: at,
      updatedAt: at,
      dueDate: dateOnly(at),
    ));
  }

  /// Creates or updates a task after validating it.
  Future<String?> saveTask(TaskItem task) {
    final at = _clock();
    final cleaned = task.copyWith(
      title: task.title.trim(),
      description: (task.description ?? '').trim().isEmpty ? null : task.description!.trim(),
      updatedAt: at,
    );
    final problems = TaskValidator.validate(cleaned, now: at, checkReminderInPast: false);
    if (problems.isNotEmpty) return Future<String?>.value(problems.values.first);
    return _mutate(() => _tasks.upsertTask(cleaned), 'save the task');
  }

  Future<String?> deleteTask(String id) => _mutate(() => _tasks.deleteTask(id), 'delete the task');

  /// Completes or reopens ONE occurrence. For a repeating task only that date
  /// changes; for a one-time task the task itself changes.
  Future<String?> setCompleted(TaskOccurrence occurrence, bool completed) {
    final at = _clock();
    final task = occurrence.task;
    final date = occurrence.date;
    if (task.isRecurring && date != null) {
      return _mutate(
        () => completed
            ? _tasks.completeOccurrence(task.id, date, at)
            : _tasks.reopenOccurrence(task.id, date, at),
        'update the task',
      );
    }
    return _mutate(
      () => _tasks.setTaskCompleted(task.id, completed: completed, at: at),
      'update the task',
    );
  }

  /// Moves a task's due date (and optionally time). A reminder keeps its offset.
  Future<String?> reschedule(TaskItem task, DateTime? newDate, int? newMinutes) {
    final at = _clock();
    final moved = task.rescheduled(newDate == null ? null : dateOnly(newDate), newMinutes, at);
    final problems = TaskValidator.validate(moved, now: at, checkReminderInPast: false);
    if (problems.isNotEmpty) return Future<String?>.value(problems.values.first);
    return _mutate(() => _tasks.upsertTask(moved), 'reschedule the task');
  }

  Future<String?> _mutate(Future<void> Function() action, String what) async {
    try {
      await action();
      sync.recordLocalChange();
      await _reload();
      return null;
    } catch (error) {
      debugPrint('DAYMARK: could not $what: $error');
      return 'Could not $what. $error';
    }
  }

  // ---- settings --------------------------------------------------------------

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    try {
      await _settings.write(SettingsRepository.themeModeKey, mode.name);
    } catch (error) {
      debugPrint('DAYMARK: could not save theme: $error');
    }
  }

  /// The header toggle: switches to the opposite of what is currently showing.
  Future<void> toggleTheme(Brightness showing) =>
      setThemeMode(showing == Brightness.dark ? ThemeMode.light : ThemeMode.dark);

  /// Turns reminders on or off. Turning ON may show the system permission prompt,
  /// so call this only from a tap. Returns the resulting permission.
  Future<NotificationPermissionStatus> setNotificationsEnabled(bool enabled) async {
    if (enabled) {
      await reminders.enable();
    } else {
      await reminders.disable();
    }
    try {
      await _settings.write(
        SettingsRepository.notificationsEnabledKey,
        reminders.enabled.toString(),
      );
    } catch (error) {
      debugPrint('DAYMARK: could not save notification setting: $error');
    }
    notifyListeners();
    return reminders.permission;
  }

  /// A notification was tapped: find the task and ask the UI to show it.
  void handleNotificationTap(String payload) {
    for (final occurrence in _occurrences) {
      if (occurrence.key == payload) {
        focusedOccurrence.value = occurrence;
        return;
      }
    }
  }

  static ThemeMode _parseTheme(String? value) {
    switch (value) {
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.light;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _firedSub?.cancel();
    reminders.dispose();
    sync.dispose();
    themeMode.dispose();
    lastFiredReminder.dispose();
    focusedOccurrence.dispose();
    final database = _database;
    if (database != null) unawaited(database.close());
    super.dispose();
  }
}
