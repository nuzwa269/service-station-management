import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One change made on the phone, waiting to be uploaded (ARCHITECTURE §4.3).
class QueuedChange {
  const QueuedChange({required this.id, required this.clientTime, required this.op, required this.args, this.held = false});

  factory QueuedChange.fromJson(Map<String, dynamic> j) => QueuedChange(
        id: j['client_change_id'] as String,
        clientTime: DateTime.parse(j['client_time'] as String),
        op: j['op'] as String,
        args: Map<String, Object?>.from(j['args'] as Map),
        held: j['held'] as bool? ?? false,
      );

  final String id;
  final DateTime clientTime;
  final String op;
  final Map<String, Object?> args;

  /// Refused for now (station read-only); kept and retried later (REQ-009).
  final bool held;

  Map<String, Object?> toJson() =>
      {'client_change_id': id, 'client_time': clientTime.toUtc().toIso8601String(), 'op': op, 'args': args, 'held': held};

  QueuedChange copyWith({bool? held}) => QueuedChange(id: id, clientTime: clientTime, op: op, args: args, held: held ?? this.held);
}

/// Local storage for the offline cache and the change queue. Survives app restarts.
abstract interface class SyncStore {
  Future<Map<String, dynamic>?> loadSnapshot();
  Future<void> saveSnapshot(Map<String, dynamic> snapshot);
  Future<List<QueuedChange>> queue();
  Future<void> enqueue(QueuedChange change);
  Future<void> remove(Iterable<String> ids);
  Future<void> markHeld(Iterable<String> ids);
  Future<DateTime?> lastSync();
  Future<void> setLastSync(DateTime at);
}

/// In-memory store for tests.
class MemorySyncStore implements SyncStore {
  Map<String, dynamic>? _snapshot;
  final List<QueuedChange> _queue = [];
  DateTime? _last;

  @override
  Future<Map<String, dynamic>?> loadSnapshot() async => _snapshot == null ? null : jsonDecode(jsonEncode(_snapshot)) as Map<String, dynamic>;
  @override
  Future<void> saveSnapshot(Map<String, dynamic> snapshot) async => _snapshot = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
  @override
  Future<List<QueuedChange>> queue() async => List.of(_queue);
  @override
  Future<void> enqueue(QueuedChange change) async => _queue.add(change);
  @override
  Future<void> remove(Iterable<String> ids) async => _queue.removeWhere((c) => ids.contains(c.id));
  @override
  Future<void> markHeld(Iterable<String> ids) async {
    for (var i = 0; i < _queue.length; i++) {
      if (ids.contains(_queue[i].id)) _queue[i] = _queue[i].copyWith(held: true);
    }
  }

  @override
  Future<DateTime?> lastSync() async => _last;
  @override
  Future<void> setLastSync(DateTime at) async => _last = at;
}

/// SQLite store on the phone (Android 8+).
class SqfliteSyncStore implements SyncStore {
  SqfliteSyncStore._(this._db);
  final Database _db;

  static Future<SqfliteSyncStore> open({String name = 'staff_sync.db'}) async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), name),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('create table kv (k text primary key, v text not null)');
        await db.execute('create table change_queue (seq integer primary key autoincrement, id text unique not null, '
            'body text not null, held integer not null default 0)');
      },
    );
    return SqfliteSyncStore._(db);
  }

  Future<String?> _get(String k) async {
    final rows = await _db.query('kv', where: 'k = ?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  Future<void> _put(String k, String v) => _db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<Map<String, dynamic>?> loadSnapshot() async {
    final s = await _get('snapshot');
    return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
  }

  @override
  Future<void> saveSnapshot(Map<String, dynamic> snapshot) => _put('snapshot', jsonEncode(snapshot));

  @override
  Future<List<QueuedChange>> queue() async {
    final rows = await _db.query('change_queue', orderBy: 'seq');
    return [
      for (final r in rows)
        QueuedChange.fromJson(jsonDecode(r['body'] as String) as Map<String, dynamic>).copyWith(held: (r['held'] as int) == 1),
    ];
  }

  @override
  Future<void> enqueue(QueuedChange change) =>
      _db.insert('change_queue', {'id': change.id, 'body': jsonEncode(change.toJson()), 'held': 0}, conflictAlgorithm: ConflictAlgorithm.ignore);

  @override
  Future<void> remove(Iterable<String> ids) async {
    final batch = _db.batch();
    for (final id in ids) {
      batch.delete('change_queue', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> markHeld(Iterable<String> ids) async {
    final batch = _db.batch();
    for (final id in ids) {
      batch.update('change_queue', {'held': 1}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<DateTime?> lastSync() async {
    final s = await _get('last_sync');
    return s == null ? null : DateTime.parse(s);
  }

  @override
  Future<void> setLastSync(DateTime at) => _put('last_sync', at.toUtc().toIso8601String());
}
