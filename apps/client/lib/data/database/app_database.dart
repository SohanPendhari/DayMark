import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Task definitions. A repeating task is ONE row (the rule); its occurrences are
/// computed, and only completions are stored (see [OccurrenceCompletions]).
///
/// Dates are `yyyy-MM-dd` local calendar dates; times are minutes since
/// midnight; instants are epoch milliseconds (UTC).
@DataClassName('TaskRow')
@TableIndex(name: 'tasks_due_date_idx', columns: {#dueDate})
@TableIndex(name: 'tasks_status_idx', columns: {#status})
@TableIndex(name: 'tasks_updated_at_idx', columns: {#updatedAt})
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable()();
  TextColumn get dueDate => text().nullable()();
  IntColumn get dueMinutes => integer().nullable()();

  /// 0 low, 1 medium, 2 high.
  IntColumn get priority => integer().withDefault(const Constant(1))();

  /// 0 pending, 1 completed. Only meaningful for one-time tasks.
  IntColumn get status => integer().withDefault(const Constant(0))();
  IntColumn get completedAt => integer().nullable()();
  IntColumn get createdAt => integer()();

  /// Bumped on every change; reserved for future synchronization.
  IntColumn get updatedAt => integer()();

  BoolColumn get reminderEnabled => boolean().withDefault(const Constant(false))();
  TextColumn get reminderDate => text().nullable()();
  IntColumn get reminderMinutes => integer().nullable()();

  /// 0 none, 1 daily, 2 weekly, 3 monthly.
  IntColumn get recurrenceType => integer().withDefault(const Constant(0))();

  /// Bit 0 = Monday ... bit 6 = Sunday.
  IntColumn get recurrenceWeekdays => integer().withDefault(const Constant(0))();
  IntColumn get recurrenceMonthDay => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Completion history of repeating tasks: one row per completed occurrence.
/// The composite key makes completing the same occurrence twice idempotent.
@DataClassName('CompletionRow')
@TableIndex(name: 'completions_task_idx', columns: {#taskId})
class OccurrenceCompletions extends Table {
  TextColumn get taskId => text()();
  TextColumn get occurrenceDate => text()();
  IntColumn get completedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {taskId, occurrenceDate};
}

/// Small key/value store for user preferences.
@DataClassName('SettingRow')
class AppSettings extends Table {
  TextColumn get settingKey => text()();
  TextColumn get settingValue => text()();

  @override
  Set<Column<Object>> get primaryKey => {settingKey};
}

@DriftDatabase(tables: [Tasks, OccurrenceCompletions, AppSettings])
class AppDatabase extends _$AppDatabase {
  /// Use with an explicit executor, e.g. `NativeDatabase.memory()` in tests.
  AppDatabase(super.e);

  /// The real database: a SQLite file on Android/desktop, SQLite compiled to
  /// WebAssembly on the web (OPFS or IndexedDB). On the web it needs
  /// `web/sqlite3.wasm` and `web/drift_worker.js` next to index.html.
  AppDatabase.open({void Function(WasmDatabaseResult)? onWebResult})
      : super(
          driftDatabase(
            name: 'daymark',
            web: DriftWebOptions(
              sqlite3Wasm: Uri.parse('sqlite3.wasm'),
              driftWorker: Uri.parse('drift_worker.js'),
              onResult: onWebResult,
            ),
          ),
        );

  /// Bump when the schema changes, and add a step to [migration].
  static const int currentSchemaVersion = 1;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // Add one block per released schema version, for example:
          //   if (from < 2) { await m.addColumn(tasks, tasks.someNewColumn); }
          // Never edit an old block: users upgrade from every version.
        },
        beforeOpen: (OpeningDetails details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
