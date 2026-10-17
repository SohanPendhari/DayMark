import 'package:daymark/services/sync_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime clock;
  SyncStateMachine make({bool configured = false}) =>
      SyncStateMachine(backendConfigured: configured, clock: () => clock);

  setUp(() => clock = DateTime(2026, 3, 10, 10));

  group('local-only mode (no backend yet)', () {
    test('starts local-only (grey)', () {
      final sync = make();
      expect(sync.status, SyncStatus.localOnly);
      expect(sync.snapshot.label, 'Local only');
      expect(sync.backendConfigured, isFalse);
    });

    test('local changes never turn it red or green', () {
      final sync = make();
      sync.recordLocalChange();
      sync.recordLocalChange();
      expect(sync.status, SyncStatus.localOnly);
      expect(sync.snapshot.pendingChanges, 2); // remembered for when sync is enabled
    });

    test('sync events cannot turn a local-only app green', () {
      final sync = make();
      sync.syncStarted();
      expect(sync.status, SyncStatus.localOnly);
      sync.syncSucceeded(acknowledgedChanges: 0);
      expect(sync.status, SyncStatus.localOnly);
    });

    test('the description says plainly that nothing is synchronized', () {
      expect(make().snapshot.description, contains('Local only'));
      expect(make().snapshot.description, contains('not set up'));
    });
  });

  group('with a configured backend', () {
    test('never synced yet is red, not green', () {
      expect(make(configured: true).status, SyncStatus.offline);
    });

    test('syncing is yellow', () {
      final sync = make(configured: true)..syncStarted();
      expect(sync.status, SyncStatus.syncing);
    });

    test('green only after the backend acknowledged everything', () {
      final sync = make(configured: true);
      sync.recordLocalChange();
      sync.syncStarted();
      expect(sync.status, SyncStatus.syncing);
      sync.syncSucceeded(acknowledgedChanges: 1);
      expect(sync.status, SyncStatus.synced);
      expect(sync.snapshot.lastSuccessfulSync, clock);
      expect(sync.snapshot.pendingChanges, 0);
    });

    test('a new local change after a sync makes it red until acknowledged', () {
      final sync = make(configured: true)
        ..recordLocalChange()
        ..syncSucceeded(acknowledgedChanges: 1);
      expect(sync.status, SyncStatus.synced);
      sync.recordLocalChange();
      expect(sync.status, SyncStatus.offline);
      expect(sync.snapshot.description, contains('1 local change is waiting'));
      sync.syncSucceeded(acknowledgedChanges: 1);
      expect(sync.status, SyncStatus.synced);
    });

    test('a partial acknowledgment stays red', () {
      final sync = make(configured: true)
        ..recordLocalChange()
        ..recordLocalChange()
        ..recordLocalChange()
        ..syncSucceeded(acknowledgedChanges: 2);
      expect(sync.status, SyncStatus.offline);
      expect(sync.snapshot.pendingChanges, 1);
      expect(sync.snapshot.description, contains('1 local change'));
    });

    test('acknowledging more than is pending never goes negative', () {
      final sync = make(configured: true)
        ..recordLocalChange()
        ..syncSucceeded(acknowledgedChanges: 50);
      expect(sync.snapshot.pendingChanges, 0);
      expect(sync.status, SyncStatus.synced);
    });

    test('a failure is red with the error, and the next success clears it', () {
      final sync = make(configured: true)
        ..syncSucceeded(acknowledgedChanges: 0)
        ..syncStarted()
        ..syncFailed('connection refused');
      expect(sync.status, SyncStatus.offline);
      expect(sync.snapshot.lastError, 'connection refused');
      expect(sync.snapshot.description, contains('connection refused'));
      sync.syncSucceeded(acknowledgedChanges: 0);
      expect(sync.status, SyncStatus.synced);
      expect(sync.snapshot.lastError, isNull);
    });

    test('losing connectivity is red; regaining it returns to synced because everything was confirmed', () {
      final sync = make(configured: true)..syncSucceeded(acknowledgedChanges: 0);
      expect(sync.status, SyncStatus.synced);
      sync.connectivityChanged(online: false);
      expect(sync.status, SyncStatus.offline);
      sync.connectivityChanged(online: true);
      expect(sync.status, SyncStatus.synced); // last sync was confirmed and nothing is pending
    });

    test('a failure with changes waiting names both the failure and the backlog', () {
      final sync = make(configured: true)
        ..recordLocalChange()
        ..recordLocalChange()
        ..syncStarted()
        ..syncFailed('timeout');
      expect(sync.snapshot.description, 'Sync failed: timeout. 2 local changes are waiting to sync.');
    });

    test('offline wording when the backend is unreachable', () {
      final sync = make(configured: true)
        ..syncSucceeded(acknowledgedChanges: 0)
        ..connectivityChanged(online: false);
      expect(sync.snapshot.description, 'Offline: the backend cannot be reached.');
      sync.recordLocalChange();
      expect(sync.snapshot.description, 'Offline: the backend cannot be reached. 1 local change is waiting to sync.');
    });

    test('un-configuring returns to local-only', () {
      final sync = make(configured: true)..syncSucceeded(acknowledgedChanges: 0);
      sync.configureBackend(false);
      expect(sync.status, SyncStatus.localOnly);
    });

    test('listeners are notified on every transition', () {
      final sync = make(configured: true);
      var calls = 0;
      sync.addListener(() => calls++);
      sync.recordLocalChange();
      sync.syncStarted();
      sync.syncFailed('x');
      sync.syncSucceeded(acknowledgedChanges: 1);
      expect(calls, 4);
    });
  });
}
