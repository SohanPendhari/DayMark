import 'reminder_planner.dart';

enum NotificationPermissionStatus {
  /// Notifications may be shown.
  granted,

  /// The user (or system) blocked them.
  denied,

  /// The user has not been asked yet.
  notDetermined,

  /// This platform or browser cannot show notifications.
  unsupported,
}

/// The platform side of reminders. Everything above this interface is
/// platform-independent and unit-tested with a fake.
abstract class NotificationGateway {
  /// True when notifications are delivered by the operating system even while
  /// the app is closed (Android). False when delivery depends on the app being
  /// open (a browser tab): browsers cannot schedule notifications.
  bool get deliversWhileClosed;

  /// Fires when a reminder is delivered while the app is open, so the UI can
  /// also show it in-app.
  Stream<PlannedReminder> get fired;

  Future<void> initialize();

  /// Current state, without prompting the user.
  Future<NotificationPermissionStatus> permissionStatus();

  /// Prompts the user. Call ONLY from a user gesture (a tap): browsers may
  /// refuse or permanently block prompts that appear without one.
  Future<NotificationPermissionStatus> requestPermission();

  /// Cancels everything previously scheduled and schedules [reminders].
  /// Notification ids are stable per occurrence, so this never duplicates.
  Future<void> replaceAll(List<PlannedReminder> reminders);

  /// Cancels all scheduled (not yet delivered) reminders.
  Future<void> cancelAll();

  Future<void> dispose();
}
