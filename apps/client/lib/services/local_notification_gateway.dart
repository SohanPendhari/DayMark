
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'notification_gateway.dart';
import 'reminder_planner.dart';

/// Local notifications for DayMark.
///
/// Android schedules notifications through the operating system, so they
/// can arrive while the app is in the background or closed. Android may delay
/// inexact alarms because of battery and power-management policies.
///
/// Web notifications use timers and require the DayMark tab to remain open.
class LocalNotificationGateway implements NotificationGateway {
  LocalNotificationGateway({this.onSelect});

  final void Function(String payload)? onSelect;

  static const Duration _webHorizon = Duration(hours: 12);

  // Use a new channel ID so Android can create a channel with sound enabled.
  // Existing Android notification channels retain their previous settings.
  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'daymark_reminders_v2',
      'Task reminders',
      channelDescription: 'Reminders for your DayMark tasks',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    ),
    web: WebNotificationDetails(),
  );

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  final StreamController<PlannedReminder> _fired =
      StreamController<PlannedReminder>.broadcast();

  final Map<int, Timer> _timers = <int, Timer>{};

  bool _ready = false;

  bool get _platformSupported =>
      kIsWeb
          ? WebFlutterLocalNotificationsPlugin.isSupported
          : defaultTargetPlatform == TargetPlatform.android;

  @override
  bool get deliversWhileClosed => !kIsWeb;

  @override
  Stream<PlannedReminder> get fired => _fired.stream;

  @override
  Future<void> initialize() async {
    if (_ready || !_platformSupported) return;

    try {
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          web: WebInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final payload = response.payload;
          if (payload != null) onSelect?.call(payload);
        },
      );

      _ready = ok ?? false;

      if (!_ready) {
        debugPrint('DAYMARK: notification plugin initialization returned false');
      }
    } catch (error, stackTrace) {
      debugPrint('DAYMARK: notification setup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _ready = false;
    }
  }

  @override
  Future<NotificationPermissionStatus> permissionStatus() async {
    if (!_platformSupported || !_ready) {
      return NotificationPermissionStatus.unsupported;
    }

    try {
      if (kIsWeb) {
        final web = _plugin.resolvePlatformSpecificImplementation<
            WebFlutterLocalNotificationsPlugin>();

        if (web == null) {
          return NotificationPermissionStatus.unsupported;
        }

        switch (web.permissionStatus) {
          case WebNotificationPermission.granted:
            return NotificationPermissionStatus.granted;
          case WebNotificationPermission.denied:
            return NotificationPermissionStatus.denied;
          case WebNotificationPermission.defaultPermissions:
            return NotificationPermissionStatus.notDetermined;
        }
      }

      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      if (android == null) {
        return NotificationPermissionStatus.unsupported;
      }

      final enabled = await android.areNotificationsEnabled();

      return enabled == true
          ? NotificationPermissionStatus.granted
          : NotificationPermissionStatus.denied;
    } catch (error) {
      debugPrint('DAYMARK: could not read notification permission: $error');
      return NotificationPermissionStatus.unsupported;
    }
  }

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    if (!_platformSupported || !_ready) {
      return NotificationPermissionStatus.unsupported;
    }

    try {
      if (kIsWeb) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                WebFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (error) {
      debugPrint('DAYMARK: notification permission request failed: $error');
    }

    return permissionStatus();
  }

  @override
  Future<void> replaceAll(List<PlannedReminder> reminders) async {
    await cancelAll();

    if (!_ready) {
      debugPrint('DAYMARK: cannot schedule reminders; plugin is not initialized');
      return;
    }

    if (kIsWeb) {
      _startWebTimers(reminders);
      return;
    }

    debugPrint('DAYMARK: scheduling ${reminders.length} reminder(s)');

    for (final reminder in reminders) {
      try {
        await _plugin.zonedSchedule(
          id: reminder.notificationId,
          scheduledDate: tz.TZDateTime.from(reminder.at, tz.UTC),
          notificationDetails: _details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          title: reminder.title,
          body: reminder.body,
          payload: reminder.key,
        );

        debugPrint(
          'DAYMARK: scheduled "${reminder.title}" for ${reminder.at}',
        );
      } catch (error, stackTrace) {
        debugPrint(
          'DAYMARK: could not schedule "${reminder.title}": $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  void _startWebTimers(List<PlannedReminder> reminders) {
    final now = DateTime.now();

    for (final reminder in reminders) {
      final delay = reminder.at.difference(now);

      if (delay.isNegative || delay > _webHorizon) continue;

      _timers[reminder.notificationId] = Timer(
        delay,
        () => _fireOnWeb(reminder),
      );
    }
  }

  Future<void> _fireOnWeb(PlannedReminder reminder) async {
    _timers.remove(reminder.notificationId);

    if (!_fired.isClosed) {
      _fired.add(reminder);
    }

    if (await permissionStatus() != NotificationPermissionStatus.granted) {
      return;
    }

    try {
      await _plugin.show(
        id: reminder.notificationId,
        title: reminder.title,
        body: reminder.body,
        notificationDetails: _details,
        payload: reminder.key,
      );
    } catch (error) {
      debugPrint('DAYMARK: browser notification failed: $error');
    }
  }

  @override
  Future<void> cancelAll() async {
    for (final timer in _timers.values) {
      timer.cancel();
    }

    _timers.clear();

    if (_ready && !kIsWeb) {
      try {
        await _plugin.cancelAllPendingNotifications();
      } catch (error) {
        debugPrint('DAYMARK: could not cancel notifications: $error');
      }
    }
  }

  @override
  Future<void> dispose() async {
    await cancelAll();
    await _fired.close();
  }
}
