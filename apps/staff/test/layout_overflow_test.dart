import 'package:app_shared/testing/real_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:app_shared/app_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:staff_app/main.dart';
import 'package:staff_app/mechanic/mechanic_screens.dart';
import 'package:station_core/station_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:staff_app/sync/own_sync_engine.dart';
import 'package:staff_app/sync/sync_store.dart';

import 'sync_engine_test.dart' show FakeServer;

/// Layout check on a small phone (360 dp wide) with large system text (130%): no text may run
/// out of its box. Flutter reports any overflow as an exception, which fails the test.
void main() {
  setUpAll(loadRealFonts);
  Future<void> phone(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('mechanic job list and job card fit with long names and big text', (tester) async {
    final server = FakeServer()
      ..snapshot = {
        'jobs': [
          {'id': 'j1', 'job_no': 1001, 'stage': 'in_progress', 'plate': 'LEA-1234', 'make': 'Toyota', 'model': 'Corolla Altis Grande 1.8',
           'customer_name': 'Muhammad Abdul Rehman Siddiqui', 'odometer_km': 185000,
           'complaints': 'Engine misfiring at idle, AC not cooling, brake pedal soft and a noise from the front suspension',
           'qc_note': 'Recheck the front left brake caliper and bleed the brakes again'},
          {'id': 'j2', 'job_no': 1002, 'stage': 'quality_check', 'plate': 'KHI-77821', 'make': 'Suzuki', 'model': 'Cultus', 'customer_name': 'Sara', 'odometer_km': 9000, 'complaints': null},
        ],
        'checklist': [
          {'id': 'c1', 'job_id': 'j1', 'name': 'Brake pads, discs and brake fluid level', 'status': 'ok', 'note': null},
          {'id': 'c2', 'job_id': 'j1', 'name': 'Coolant', 'status': 'not_checked', 'note': null},
        ],
        'lines': [
          {'id': 'l1', 'job_id': 'j1', 'description': 'Engine oil 5W-30 fully synthetic (per litre)', 'qty': 3.5, 'status': 'approved'},
          {'id': 'l2', 'job_id': 'j1', 'description': 'Spark plug iridium', 'qty': 4, 'status': 'extra_pending'},
        ],
        'items': [
          {'id': 'filter', 'code': 'F1', 'name': 'Oil filter Corolla / City / Civic', 'unit': 'piece', 'barcode': null, 'on_hand': 1},
        ],
      };
    final engine = OwnSyncEngine(store: MemorySyncStore(), transport: server);
    await engine.start();
    await engine.syncNow();

    await phone(tester, MechanicHome(engine: engine, stationName: 'Demo Auto Care, Gulberg Lahore', onSignOut: () {}, autoSync: false));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('job-1001')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner dashboard, messages and alerts fit with long text', (tester) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = <String, Object>{
      'rpc/station_dashboard_totals': {'dues_paisa': 12345600, 'low_stock': 12, 'messages_to_send': 27, 'pending_approvals': 3,
        'jobs_by_stage': {'in_progress': 14, 'ready': 9, 'awaiting_approval': 6, 'quality_check': 2}},
      'rpc/station_day_summary': {'day': '2026-11-16', 'expected': {'cash': 125000000, 'jazzcash': 3450000, 'easypaisa': 1200000, 'card': 9800000, 'bank': 15000000}, 'count': 41, 'closed': false, 'closing': null},
      'approval_inbox': [
        {'id': 'a1', 'type': 'credit_release', 'status': 'pending', 'reason': 'Regular fleet customer, pays at the end of every month by bank transfer',
         'requested_by': 'u1', 'requested_by_name': 'Nadia Cashier with a long name', 'created_at': now, 'payload': {}, 'amount_paisa': 4567800},
      ],
      'message_outbox': [
        {'id': 1, 'event': 'invoice_issued', 'channel': 'whatsapp', 'status': 'manual', 'title': 'Invoice issued',
         'body': 'Your invoice INV-0042 from Demo Auto Care, Gulberg Lahore: Rs 31,500. Thank you!', 'created_at': now,
         'to_mobile': '03001234567', 'manual_reason': 'Automatic send failed: Meta could not deliver the message to this number', 'ref_id': 'x',
         'customer': {'name': 'Muhammad Abdul Rehman Siddiqui'}},
      ],
      'notifications': [
        {'id': 1, 'kind': 'approval_request', 'title': 'Credit release approval needed for invoice INV-0042', 'body': 'Regular fleet customer · Rs 45,678',
         'ref_id': 'a1', 'created_at': now, 'read_at': null},
      ],
    };
    final fake = MockClient((req) async {
      final key = req.url.path.split('/rest/v1/').last;
      return http.Response(jsonEncode(rows[key] ?? <dynamic>[]), 200, request: req, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final api = StationApi(SupabaseClient('https://demo.test', 'publishable-key', httpClient: fake,
        authOptions: const AuthClientOptions(autoRefreshToken: false)));
    final ent = Entitlements.fromRow({'plan_code': 'premium', 'effective_plan': 'premium', 'status': 'active', 'features': ['core', 'approvals_inbox'], 'renews_at': null});
    await phone(tester, StaffHome(stationName: 'Demo Auto Care, Gulberg Lahore', role: MemberRole.owner, entitlements: ent, onSignOut: () {}, api: api, stationId: 's1'));
    expect(tester.takeException(), isNull, reason: 'dashboard');
    if (const bool.fromEnvironment('SHOTS')) await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/office-dashboard.png'));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'dashboard scrolled');
    for (final tab in ['Messages', 'Alerts']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
      if (const bool.fromEnvironment('SHOTS')) await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/office-${tab.toLowerCase()}.png'));
    }
  });
}
