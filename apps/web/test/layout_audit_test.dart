// Layout audit of every web dashboard page with the demo station's real data, at phone, tablet
// and computer widths. Fails when any text runs out of its box (Flutter overflow errors).
//
// Data: test/fixtures/web_demo.json — the exact server answers for the requests these pages make,
// recorded by tools/db-check/record-web-fixtures.mjs. Requests with no recorded answer get an
// empty list and are written to test/fixtures/web_misses.json, so the recorder can fetch them.
//   flutter test test/layout_audit_test.dart                         (check)
//   flutter test test/layout_audit_test.dart --dart-define=SHOTS=true --update-goldens  (pictures)
import 'dart:convert';
import 'dart:io';

import 'package:app_shared/app_shared.dart';
import 'package:app_shared/testing/real_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:station_core/station_core.dart';
import 'package:station_web/main.dart';
import 'package:station_web/router.dart';
import 'package:station_web/screens/shell.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String requestKey(http.BaseRequest req, String body) {
  final accept = req.headers['Accept'] ?? req.headers['accept'] ?? '';
  final single = accept.contains('pgrst.object') ? ' [single]' : '';
  return '${req.method} ${req.url.path.split('/rest/v1/').last}?${req.url.query}${body.isEmpty ? '' : ' $body'}$single';
}

void main() {
  setUpAll(loadRealFonts);
  final file = File('test/fixtures/web_demo.json');
  final fx = file.existsSync() ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic> : <String, dynamic>{};
  final answers = Map<String, dynamic>.from(fx['answers'] as Map? ?? {});
  final misses = <String, Map<String, String>>{};

  final fake = MockClient((req) async {
    final body = req.body;
    final key = requestKey(req, body);
    if (!answers.containsKey(key)) {
      misses[key] = {'method': req.method, 'url': req.url.toString(), 'body': body, 'accept': req.headers['Accept'] ?? ''};
    }
    final a = answers[key] ?? (key.endsWith('[single]') ? null : <dynamic>[]);
    if (a == null) return http.Response('{"code":"PGRST116","message":"no rows"}', 406, request: req);
    return http.Response(jsonEncode(a), 200, request: req, headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final api = StationApi(SupabaseClient('https://demo.test', 'publishable-key', httpClient: fake,
      authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final session = StationSession(api)
    ..current = Membership(
      id: 'm1',
      stationId: (fx['station_id'] as String?) ?? '00000000-0000-0000-0000-000000000000',
      stationName: 'Demo Auto Care',
      stationCode: 'DEMO1',
      role: MemberRole.owner,
      active: true,
    )
    ..entitlements = Entitlements.fromRow({
      'plan_code': 'premium', 'effective_plan': 'premium', 'status': 'trial',
      'features': ['core', 'booking', 'approvals_inbox', 'audit_log_view', 'payroll', 'profit_reports', 'supplier_ledger', 'whatsapp_auto'],
      'renews_at': DateTime.now().add(const Duration(days: 40)).toIso8601String(),
    });
  session.memberships = [session.current!];

  tearDownAll(() {
    File('test/fixtures/web_misses.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(misses));
  });

  const widths = {'phone': Size(390, 844), 'tablet': Size(820, 1180), 'computer': Size(1366, 900)};
  for (final w in widths.entries) {
    for (final m in menuFor(MemberRole.owner)) {
      testWidgets('${m.name} on ${w.key}', (tester) async {
        tester.view.physicalSize = w.value * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(SessionScope(
          session: session,
          child: MaterialApp(theme: appTheme(), debugShowCheckedModeBanner: false,
              home: StationShell(location: '/${m.name}', child: screenFor(m))),
        ));
        if (const bool.fromEnvironment('DEBUG_PAGE')) {
          for (var i = 0; i < 3; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
            await tester.pump(const Duration(milliseconds: 100));
          }
          debugPrint('spinners: ${find.byType(CircularProgressIndicator).evaluate().length}  linear: ${find.byType(LinearProgressIndicator).evaluate().length}');
          debugPrint('texts: ${find.byType(Text).evaluate().take(30).map((e) => (e.widget as Text).data).join(' | ')}');
          return;
        }
        // Large answers are decoded on a background isolate, which needs real time to finish.
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        final problems = <String>[];
        Object? e;
        while ((e = tester.takeException()) != null) {
          problems.add(e.toString().split('\n').first);
        }
        if (const bool.fromEnvironment('SHOTS')) {
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${w.key}-${m.name}.png'));
        }
        expect(problems, isEmpty, reason: '${m.label} on ${w.key}');
      });
    }
  }
}
