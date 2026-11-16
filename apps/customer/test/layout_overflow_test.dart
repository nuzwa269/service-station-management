import 'dart:convert';
import 'dart:io';

import 'package:app_shared/app_shared.dart';
import 'package:customer_app/home.dart';
import 'package:customer_app/station_screens.dart';
import 'package:app_shared/testing/real_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Every customer-app screen on a small phone (360 dp) with large system text (130%), using the
/// demo customer's real data (test/fixtures/demo.json). Any text running out of its box makes
/// Flutter report an overflow, which fails the test.
void main() {
  setUpAll(loadRealFonts);
  final fx = jsonDecode(File('test/fixtures/demo.json').readAsStringSync()) as Map<String, dynamic>;
  final invoice = {
    'id': 'inv1', 'invoice_no': 1042, 'job_no': 1003, 'plate': 'LEA-1234', 'customer': 'Muhammad Abdul Rehman Siddiqui',
    'issued_at': '2026-11-16T10:00:00+00:00',
    'station': {'name': 'Demo Auto Care', 'address': '12-B Main Boulevard, Gulberg III', 'city': 'Lahore', 'phone': '0300-0000000', 'ntn': '1234567-8'},
    'balance': {'paid_paisa': 2000000, 'due_paisa': 1150000},
    'lines': [
      {'description': 'Engine oil 5W-30 fully synthetic (per litre)', 'qty': 3.5, 'unit_price_paisa': 110000, 'total_paisa': 385000, 'warranty_days': 0},
      {'description': 'Battery 55Ah maintenance free', 'qty': 1, 'unit_price_paisa': 2150000, 'total_paisa': 2150000, 'warranty_days': 365},
    ],
    'parts_paisa': 2535000, 'labour_paisa': 615000, 'discount_paisa': 0, 'tax_paisa': 0, 'total_paisa': 3150000,
  };
  final rpc = <String, Object?>{
    'customer_stations': fx['customer_stations'],
    'customer_station_data': fx['customer_station_data'],
    'customer_job': fx['customer_job'],
    'booking_slots': fx['booking_slots'],
    'customer_vehicle_history': fx['customer_vehicle_history'],
    'customer_notifications_list': fx['customer_notifications_list'],
    'customer_invoice': invoice,
  };
  final fake = MockClient((req) async {
    final p = req.url.path;
    final body = p.contains('/rpc/') ? rpc[p.split('/rpc/').last] ?? <dynamic>[] : <dynamic>[];
    return http.Response(jsonEncode(body), 200, request: req, headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final api = StationApi(SupabaseClient('https://demo.test', 'publishable-key', httpClient: fake));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: CustomerHome(api: api),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  var shot = 0;
  Future<void> look(WidgetTester tester, String where) async {
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('SHOTS')) {
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${++shot}-${where.replaceAll(RegExp(r'[^a-z]+'), '-')}.png'));
    }
    final e = tester.takeException();
    expect(e, isNull, reason: 'layout problem on: $where');
  }

  testWidgets('customer screens fit on a small phone with big text', (tester) async {
    await open(tester);
    await look(tester, 'home');
    await tester.tap(find.text('Demo Auto Care').first);
    await look(tester, 'station · bookings');
    for (final tab in ['Jobs', 'Invoices', 'Vehicles']) {
      await tester.tap(find.widgetWithText(Tab, tab));
      await look(tester, 'station · $tab');
    }
    // Job tracking with the estimate waiting for approval.
    await tester.tap(find.widgetWithText(Tab, 'Jobs'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Job #').first);
    await look(tester, 'job tracking');
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -1600));
    await look(tester, 'job tracking (scrolled)');
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Vehicle history.
    await tester.tap(find.widgetWithText(Tab, 'Vehicles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History').first);
    await look(tester, 'vehicle history');
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Booking a slot.
    await tester.tap(find.widgetWithText(Tab, 'Bookings'));
    await tester.pumpAndSettle();
    final book = find.textContaining('Book');
    if (book.evaluate().isNotEmpty) {
      await tester.tap(book.first);
      await look(tester, 'book a slot');
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Notifications.
    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await look(tester, 'notifications');
  });

  testWidgets('invoice screen fits on a small phone with big text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(360, 780), textScaler: TextScaler.linear(1.3)),
        child: InvoiceScreen(api: api, invoiceId: 'inv1'),
      ),
    ));
    await look(tester, 'invoice');
  });
}
