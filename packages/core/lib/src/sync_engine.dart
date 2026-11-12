/// Interface the Staff app talks to for offline work (ARCHITECTURE §4.3, DEC-031).
/// Our own engine implements it at launch (TASK-034); PowerSync can replace it later
/// without changing screens or server functions.
abstract interface class SyncEngine {
  /// Queues a change locally (survives restarts). [op] names the server function,
  /// e.g. "job_add_part"; the engine assigns client_change_id and client_time.
  Future<void> enqueue(String op, Map<String, Object?> args);

  /// Pulls changed rows since the last sync, then pushes queued changes in order.
  Future<SyncResult> syncNow();

  Stream<SyncStatus> get status;
}

class SyncStatus {
  const SyncStatus({
    required this.online,
    required this.pendingCount,
    required this.heldCount,
    this.lastSyncAt,
  });

  final bool online;
  final int pendingCount;

  /// Changes refused by the server for now (e.g. station read-only, REQ-009).
  final int heldCount;
  final DateTime? lastSyncAt;

  /// REQ-023: warn after 24 h without a sync.
  bool overdue(DateTime now) =>
      lastSyncAt != null && now.difference(lastSyncAt!) > const Duration(hours: 24);
}

class SyncResult {
  const SyncResult({required this.applied, required this.duplicates, required this.held, required this.conflicts});
  final int applied;
  final int duplicates;
  final int held;
  final int conflicts;
}
