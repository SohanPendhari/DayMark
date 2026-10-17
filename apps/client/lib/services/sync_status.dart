import 'package:flutter/foundation.dart';

import '../models/date_utils.dart';

/// What the header indicator shows.
///
/// * localOnly - grey:   no backend is configured. Nothing is being synchronized.
/// * synced    - green:  the backend has ACKNOWLEDGED every local change.
/// * syncing   - yellow: a synchronization request is in progress.
/// * offline   - red:    the backend is unreachable, the last attempt failed,
///                       local changes are still waiting, or nothing has been
///                       acknowledged yet.
enum SyncStatus { localOnly, synced, syncing, offline }

@immutable
class SyncSnapshot {
  const SyncSnapshot({
    required this.status,
    this.pendingChanges = 0,
    this.lastSuccessfulSync,
    this.lastError,
    this.isOnline = true,
  });

  final SyncStatus status;

  /// Local changes the backend has not acknowledged yet.
  final int pendingChanges;
  final DateTime? lastSuccessfulSync;
  final String? lastError;

  /// False when the backend cannot be reached.
  final bool isOnline;

  String get label {
    switch (status) {
      case SyncStatus.localOnly:
        return 'Local only';
      case SyncStatus.synced:
        return 'Synced';
      case SyncStatus.syncing:
        return 'Syncing';
      case SyncStatus.offline:
        return 'Offline';
    }
  }

  /// Sentence for tooltips and screen readers.
  String get description {
    switch (status) {
      case SyncStatus.localOnly:
        return 'Local only: backend sync is not set up. Your tasks are saved on this device.';
      case SyncStatus.synced:
        final at = lastSuccessfulSync;
        return at == null
            ? 'Synced with the backend.'
            : 'Synced with the backend. Last sync ${formatDate(at)} ${formatMinutes(at.hour * 60 + at.minute)}.';
      case SyncStatus.syncing:
        return 'Syncing with the backend…';
      case SyncStatus.offline:
        final waiting = pendingChanges == 0
            ? ''
            : (pendingChanges == 1
                ? '1 local change is waiting to sync.'
                : '$pendingChanges local changes are waiting to sync.');
        final error = lastError;
        if (error != null) return waiting.isEmpty ? 'Sync failed: $error' : 'Sync failed: $error. $waiting';
        if (!isOnline) {
          return waiting.isEmpty
              ? 'Offline: the backend cannot be reached.'
              : 'Offline: the backend cannot be reached. $waiting';
        }
        if (waiting.isNotEmpty) return 'Offline or unsynced: $waiting';
        return 'Offline or unsynced: nothing has been confirmed by the backend yet.';
    }
  }
}

/// Tracks synchronization state. It deliberately contains NO networking: a future
/// sync engine drives it through the methods below, and the UI only reads
/// [snapshot]. Until a backend exists, [backendConfigured] stays false and the
/// state is permanently [SyncStatus.localOnly].
class SyncStateMachine extends ChangeNotifier {
  SyncStateMachine({bool backendConfigured = false, DateTime Function()? clock})
      : _configured = backendConfigured,
        _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  bool _configured;
  bool _syncing = false;
  bool _online = true;
  int _pending = 0;
  DateTime? _lastSuccess;
  String? _lastError;

  bool get backendConfigured => _configured;

  SyncSnapshot get snapshot {
    final SyncStatus status;
    if (!_configured) {
      status = SyncStatus.localOnly;
    } else if (_syncing) {
      status = SyncStatus.syncing;
    } else if (!_online || _lastError != null || _pending > 0 || _lastSuccess == null) {
      // Green requires an acknowledgment. Never synced, failed, offline, or
      // changes waiting: all of these are red.
      status = SyncStatus.offline;
    } else {
      status = SyncStatus.synced;
    }
    return SyncSnapshot(
      status: status,
      pendingChanges: _pending,
      lastSuccessfulSync: _lastSuccess,
      lastError: _lastError,
      isOnline: _online,
    );
  }

  SyncStatus get status => snapshot.status;

  /// Called by the future sync setup once a backend is configured and paired.
  void configureBackend(bool configured) {
    if (_configured == configured) return;
    _configured = configured;
    _syncing = false;
    notifyListeners();
  }

  /// Every local create/edit/complete/delete calls this. In local-only mode the
  /// count is still tracked, so enabling sync later knows work is waiting.
  void recordLocalChange() {
    _pending += 1;
    notifyListeners();
  }

  void syncStarted() {
    _syncing = true;
    notifyListeners();
  }

  /// The backend confirmed [acknowledgedChanges] changes.
  void syncSucceeded({required int acknowledgedChanges}) {
    _syncing = false;
    _pending = (_pending - acknowledgedChanges).clamp(0, 1 << 30).toInt();
    _lastError = null;
    _lastSuccess = _clock();
    notifyListeners();
  }

  void syncFailed(String error) {
    _syncing = false;
    _lastError = error;
    notifyListeners();
  }

  void connectivityChanged({required bool online}) {
    if (_online == online) return;
    _online = online;
    notifyListeners();
  }
}
