import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:staff_app/mechanic/mechanic_screens.dart';
import 'package:staff_app/sync/own_sync_engine.dart';
import 'package:staff_app/sync/sync_store.dart';

/// Fake server: keeps a snapshot, records applied change ids, can be offline or read-only.
class FakeServer implements SyncTransport {
  bool offline = false;
  bool readOnly = false;
  final applied = <String>[];
  final received = <List<String>>[];
  Map<String, dynamic> snapshot = {
    'jobs': [
      {'id': 'j1', 'job_no': 1001, 'stage': 'approved', 'plate': 'LEA-1234', 'make': 'Toyota', 'model': 'Corolla', 'customer_name': 'Ali', 'odometer_km': 85000, 'complaints': 'Service'},
    ],
    'checklist': [
      {'id': 'c1', 'job_id': 'j1', 'name': 'Brakes', 'status': 'not_checked', 'note': null},
    ],
    'lines': <Map<String, dynamic>>[],
    'items': [
      {'id': 'filter', 'code': 'F1', 'name': 'Oil filter', 'unit': 'piece', 'barcode': null, 'on_hand': 1},
    ],
  };

  @override
  Future<Map<String, dynamic>> pull() async {
    if (offline) throw Exception('no network');
    return snapshot;
  }

  @override
  Future<List<Map<String, dynamic>>> apply(List<Map<String, Object?>> changes) async {
    if (offline) throw Exception('no network');
    received.add([for (final c in changes) c['client_change_id'] as String]);
    return [
      for (final c in changes)
        if (readOnly)
          {'client_change_id': c['client_change_id'], 'status': 'held'}
        else if (applied.contains(c['client_change_id']))
          {'client_change_id': c['client_change_id'], 'status': 'duplicate'}
        else ...[
          {'client_change_id': c['client_change_id'], 'status': 'applied'},
        ],
    ]..forEach((r) {
        if (r['status'] == 'applied') applied.add(r['client_change_id'] as String);
      });
  }
}

void main() {
  late MemorySyncStore store;
  late FakeServer server;
  late OwnSyncEngine engine;

  setUp(() async {
    store = MemorySyncStore();
    server = FakeServer();
    engine = OwnSyncEngine(store: store, transport: server);
    await engine.start();
    await engine.syncNow();
  });

  test('TEST-023: offline changes queue, show at once and upload in order', () async {
    server.offline = true;
    await engine.enqueue('stage', {'job_id': 'j1', 'stage': 'in_progress'});
    await engine.enqueue('part_add', {'line_id': engine.newId(), 'job_id': 'j1', 'item_id': 'filter', 'qty': 1});

    // Visible locally while offline.
    expect((engine.snapshot['jobs'] as List).first['stage'], 'in_progress');
    expect((engine.snapshot['items'] as List).first['on_hand'], 0);
    expect((engine.snapshot['lines'] as List), hasLength(1));
    final status = await engine.currentStatus();
    expect(status.pendingCount, 2);

    await engine.syncNow(); // still offline
    expect((await engine.currentStatus()).online, isFalse);
    expect(await store.queue(), hasLength(2));

    server.offline = false;
    final r = await engine.syncNow();
    expect(r.applied, 2);
    expect(await store.queue(), isEmpty);
    final ops = server.received.last;
    final queued = server.applied;
    expect(ops, queued, reason: 'uploaded in the order they were made');
  });

  test('queue survives an app restart (new engine on the same store)', () async {
    server.offline = true;
    await engine.enqueue('check', {'check_id': 'c1', 'status': 'ok', 'note': null});
    final restarted = OwnSyncEngine(store: store, transport: server);
    await restarted.start();
    expect((restarted.snapshot['checklist'] as List).first['status'], 'ok');
    expect((await restarted.currentStatus()).pendingCount, 1);
    server.offline = false;
    await restarted.syncNow();
    expect(await store.queue(), isEmpty);
  });

  test('a repeated upload is a duplicate, not applied twice', () async {
    await engine.enqueue('check', {'check_id': 'c1', 'status': 'ok', 'note': null});
    final id = (await store.queue()).single.id;
    server.applied.add(id); // server already got it, but the phone missed the answer
    final r = await engine.syncNow();
    expect(r.duplicates, 1);
    expect(r.applied, 0);
    expect(await store.queue(), isEmpty);
  });

  test('REQ-009: held changes stay on the phone and go up after renewal', () async {
    server.readOnly = true;
    await engine.enqueue('part_add', {'line_id': engine.newId(), 'job_id': 'j1', 'item_id': 'filter', 'qty': 1});
    final r = await engine.syncNow();
    expect(r.held, 1);
    final q = await store.queue();
    expect(q.single.held, isTrue);
    expect((engine.snapshot['lines'] as List), hasLength(1), reason: 'still shown locally');
    server.readOnly = false;
    await engine.syncNow();
    expect(await store.queue(), isEmpty);
  });

  test('ids are valid v4 UUIDs', () {
    final id = engine.newId();
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id), isTrue);
    expect(engine.newId(), isNot(id));
  });

  testWidgets('SCR-031/032: offline badge, start work, checklist gate', (tester) async {
    server.offline = true;
    await tester.pumpWidget(MaterialApp(home: MechanicHome(engine: engine, stationName: 'Garage', onSignOut: () {}, autoSync: false)));
    await tester.pumpAndSettle();
    expect(find.text('#1001 · LEA-1234'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);

    await tester.tap(find.byKey(const Key('job-1001')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stage-next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Finish checklist (1 left)'), findsOneWidget);
    expect(find.textContaining('Offline · 1'), findsOneWidget);
  });
}
