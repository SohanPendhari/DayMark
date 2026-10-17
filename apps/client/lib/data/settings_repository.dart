import 'package:drift/drift.dart';

import 'database/app_database.dart';

/// Persistent user preferences (theme, notifications). Stored in the database so
/// they survive browser refreshes the same way tasks do.
class SettingsRepository {
  SettingsRepository(this._db);

  static const String themeModeKey = 'themeMode';
  static const String notificationsEnabledKey = 'notificationsEnabled';

  final AppDatabase _db;

  Future<String?> read(String key) async {
    final row = await (_db.select(_db.appSettings)..where((s) => s.settingKey.equals(key)))
        .getSingleOrNull();
    return row?.settingValue;
  }

  Future<void> write(String key, String value) async {
    await _db.into(_db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion(settingKey: Value(key), settingValue: Value(value)),
        );
  }
}
