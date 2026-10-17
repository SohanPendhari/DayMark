import 'package:drift_flutter/drift_flutter.dart';

/// Where the database really lives. On the web the browser decides, and some
/// situations (for example private browsing) fall back to memory, which would
/// silently lose data on refresh. The app shows a warning when that happens.
class StorageInfo {
  String _description = 'Local SQLite database';
  bool _persistent = true;

  String get description => _description;

  /// False only when the browser fell back to memory.
  bool get isPersistent => _persistent;

  void recordWebResult(WasmDatabaseResult result) {
    final impl = result.chosenImplementation;
    _persistent = impl != WasmStorageImplementation.inMemory;
    _description = _persistent
        ? 'Browser storage (${impl.name})'
        : 'Temporary memory (the browser blocked persistent storage)';
  }
}
