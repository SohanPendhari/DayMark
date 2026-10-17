
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/task_occurrence.dart';
import 'notification_gateway.dart';
import 'reminder_planner.dart';

/// Keeps scheduled notifications in step with the tasks.
///
/// Call [update] whenever tasks change (create, edit, complete, reschedule,
/// delete), at start-up, and when the user changes the notification setting.
/// Each call REPLACES the whole schedule using stable ids, so there are no
/// duplicates and nothing stale survives.
class ReminderService extends ChangeNotifier {
  ReminderService(
    this._gateway, {
    DateTime Function()? clock,
    Duration refreshInterval = const Duration(minutes: 10),
  })  : _clock = clock ?? DateTime.now,
        _refreshInterval = refreshInterval;

  final NotificationGateway _gateway;
  final DateTime Function() _clock;
  final Duration _refreshInterval;

  bool _enabled = false;
  NotificationPermissionStatus _permission =
      NotificationPermissionStatus.notDetermined;
  List<PlannedReminder> _planned = const <PlannedReminder>[];
  List<TaskOccurrence> _occurrences = const <TaskOccurrence>[];

  bool _running = false;
  bool _disposed = false;
  bool _again = false;
  Timer? _refresh;
  String? _lastError;

  /// The user's choice (persisted by the caller).
  bool get enabled => _enabled;
  NotificationPermissionStatus get permission => _permission;

  /// Reminders will actually be delivered: enabled AND permitted.
  bool get isActive =>
      _enabled && _permission == NotificationPermissionStatus.granted;

  List<PlannedReminder> get planned => _planned;
  bool get deliversWhileClosed => _gateway.deliversWhileClosed;
  Stream<PlannedReminder> get fired => _gateway.fired;
  String? get lastError => _lastError;

  Future<void> initialize({required bool enabled}) async {
    if (_disposed) return;

    _enabled = enabled;
    await _gateway.initialize();

    if (_disposed) return;

    _permission = await _gateway.permissionStatus();

    if (_disposed) return;

    if (!_gateway.deliversWhileClosed &&
        _refreshInterval > Duration.zero) {
      _refresh?.cancel();
      _refresh = Timer.periodic(
        _refreshInterval,
        (_) => unawaited(_reschedule()),
      );
    }

    notifyListeners();
  }

  /// Turns reminders on. MUST be called from a user gesture because it may show
  /// the permission prompt. Returns the resulting permission.
  Future<NotificationPermissionStatus> enable() async {
    if (_disposed) return _permission;

    _permission = await _gateway.requestPermission();

    if (_disposed) return _permission;

    _enabled = _permission == NotificationPermissionStatus.granted;
    await _reschedule();

    return _permission;
  }

  Future<void> disable() async {
    if (_disposed) return;

    _enabled = false;
    await _reschedule();
  }

  /// Re-plan from the latest tasks.
  Future<void> update(List<TaskOccurrence> occurrences) async {
    if (_disposed) return;

    _occurrences = occurrences;
    await _reschedule();
  }

  Future<void> _reschedule() async {
    if (_disposed) return;

    if (_running) {
      // Run once more with the newest data when the current pass ends.
      _again = true;
      return;
    }

    _running = true;

    try {
      do {
        _again = false;

        if (_disposed) return;

        _permission = await _gateway.permissionStatus();

        if (_disposed) return;

        if (isActive) {
          _planned = ReminderPlanner.plan(_occurrences, _clock());
          await _gateway.replaceAll(_planned);
        } else {
          _planned = const <PlannedReminder>[];
          await _gateway.cancelAll();
        }

        if (_disposed) return;

        _lastError = null;
      } while (_again && !_disposed);
    } catch (error) {
      if (!_disposed) {
        _lastError = error.toString();
      }
    } finally {
      _running = false;

      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;

    _disposed = true;
    _again = false;
    _refresh?.cancel();
    _refresh = null;

    // Gateway disposal is asynchronous; don't block ChangeNotifier.dispose().
    unawaited(_gateway.dispose());

    super.dispose();
  }
}
