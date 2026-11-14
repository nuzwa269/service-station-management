import 'dart:async';
import 'dart:math';

import 'package:station_core/station_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_store.dart';

/// Talks to the server functions sync_pull / sync_apply.
abstract interface class SyncTransport {
  Future<Map<String, dynamic>> pull();
  Future<List<Map<String, dynamic>>> apply(List<Map<String, Object?>> changes);
}

class SupabaseSyncTransport implements SyncTransport {
  SupabaseSyncTransport(this.client, this.stationId);
  final SupabaseClient client;
  final String stationId;

  @override
  Future<Map<String, dynamic>> pull() async =>
      Map<String, dynamic>.from(await client.rpc('sync_pull', params: {'p_station': stationId}) as Map);

  @override
  Future<List<Map<String, dynamic>>> apply(List<Map<String, Object?>> changes) async =>
      (await client.rpc('sync_apply', params: {'p_station': stationId, 'p_changes': changes}) as List).cast<Map<String, dynamic>>();
}

/// Our own offline engine (DEC-031). Changes are written to the local queue and applied to the
/// local snapshot at once, so the mechanic sees them while offline. syncNow() uploads the queue
/// in order, then downloads a fresh snapshot and re-applies anything still queued (held changes).
class OwnSyncEngine implements SyncEngine {
  OwnSyncEngine({required this.store, required this.transport, DateTime Function()? clock, Random? random})
      : _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final SyncStore store;
  final SyncTransport transport;
  final DateTime Function() _clock;
  final Random _random;
  final _status = StreamController<SyncStatus>.broadcast();
  bool _online = true;
  bool _syncing = false;
  Map<String, dynamic> _snapshot = const {'jobs': [], 'checklist': [], 'lines': [], 'items': []};

  /// What the screens show: server snapshot plus local pending changes.
  Map<String, dynamic> get snapshot => _snapshot;

  @override
  Stream<SyncStatus> get status => _status.stream;

  Future<void> start() async {
    _snapshot = await _withQueue(await store.loadSnapshot() ?? _snapshot);
    await _emit();
  }

  /// New random v4 UUID, so the server can use it for idempotency and as the new line id.
  String newId() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  Future<void> enqueue(String op, Map<String, Object?> args) async {
    final change = QueuedChange(id: newId(), clientTime: _clock().toUtc(), op: op, args: args);
    await store.enqueue(change);
    _snapshot = _applyLocal(_snapshot, change);
    await _emit();
  }

  @override
  Future<SyncResult> syncNow() async {
    if (_syncing) return const SyncResult(applied: 0, duplicates: 0, held: 0, conflicts: 0);
    _syncing = true;
    var applied = 0, duplicates = 0, held = 0, conflicts = 0;
    try {
      final queue = await store.queue();
      if (queue.isNotEmpty) {
        final results = await transport.apply([
          for (final c in queue) {'client_change_id': c.id, 'client_time': c.clientTime.toUtc().toIso8601String(), 'op': c.op, 'args': c.args},
        ]);
        final done = <String>[];
        final heldIds = <String>[];
        for (final r in results) {
          final id = r['client_change_id'] as String;
          switch (r['status']) {
            case 'held':
              heldIds.add(id);
              held++;
            case 'duplicate':
              done.add(id);
              duplicates++;
            case 'conflict':
              done.add(id);
              conflicts++;
            default: // applied, rejected
              done.add(id);
              applied++;
          }
        }
        await store.remove(done);
        await store.markHeld(heldIds);
      }
      final fresh = await transport.pull();
      await store.saveSnapshot(fresh);
      await store.setLastSync(_clock().toUtc());
      _snapshot = await _withQueue(fresh);
      _online = true;
    } catch (_) {
      _online = false; // keep everything queued; try again later
    } finally {
      _syncing = false;
      await _emit();
    }
    return SyncResult(applied: applied, duplicates: duplicates, held: held, conflicts: conflicts);
  }

  Future<SyncStatus> currentStatus() async {
    final q = await store.queue();
    return SyncStatus(online: _online, pendingCount: q.length, heldCount: q.where((c) => c.held).length, lastSyncAt: await store.lastSync());
  }

  Future<void> _emit() async => _status.add(await currentStatus());

  Future<Map<String, dynamic>> _withQueue(Map<String, dynamic> base) async {
    var s = base;
    for (final c in await store.queue()) {
      s = _applyLocal(s, c);
    }
    return s;
  }

  /// Optimistic local copy of what the server will do. The server re-checks every rule.
  static Map<String, dynamic> _applyLocal(Map<String, dynamic> snap, QueuedChange c) {
    List<Map<String, dynamic>> list(String k) => [for (final e in (snap[k] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    final jobs = list('jobs');
    final checklist = list('checklist');
    final lines = list('lines');
    final items = list('items');
    final a = c.args;
    switch (c.op) {
      case 'check':
        for (final k in checklist) {
          if (k['id'] == a['check_id']) {
            k['status'] = a['status'];
            k['note'] = a['note'];
          }
        }
      case 'stage':
        for (final j in jobs) {
          if (j['id'] == a['job_id']) j['stage'] = a['stage'];
        }
      case 'part_add':
        final item = items.where((i) => i['id'] == a['item_id']).firstOrNull;
        if (!lines.any((l) => l['id'] == a['line_id'])) {
          lines.add({
            'id': a['line_id'],
            'job_id': a['job_id'],
            'kind': 'part',
            'item_id': a['item_id'],
            'description': item?['name'] ?? 'Part',
            'qty': a['qty'],
            'status': 'extra_pending',
            'mine': true,
            'pending': true,
          });
          if (item != null) item['on_hand'] = (item['on_hand'] as num) - (a['qty'] as num);
        }
      case 'part_remove':
        final line = lines.where((l) => l['id'] == a['line_id']).firstOrNull;
        if (line != null) {
          lines.remove(line);
          final item = items.where((i) => i['id'] == line['item_id']).firstOrNull;
          if (item != null) item['on_hand'] = (item['on_hand'] as num) + (line['qty'] as num);
        }
    }
    return {...snap, 'jobs': jobs, 'checklist': checklist, 'lines': lines, 'items': items};
  }

  Future<void> dispose() => _status.close();
}
