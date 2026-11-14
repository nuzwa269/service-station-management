import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_core/station_core.dart';
import 'package:station_web/screens/shell.dart';

Entitlements _ent(String plan, String status, List<String> features, {int days = 10}) => Entitlements.fromRow({
      'plan_code': plan,
      'effective_plan': plan,
      'status': status,
      'features': features,
      'renews_at': DateTime.now().add(Duration(days: days)).toIso8601String(),
    });

Widget _shell({required MemberRole role, required Entitlements ent, required String location, List<String>? navLog}) =>
    MaterialApp(
      theme: appTheme(),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1280, 900)),
        child: StationShellView(
          stationName: 'Delta Service Station',
          role: role,
          entitlements: ent,
          location: location,
          onNavigate: (p) => navLog?.add(p),
          onSignOut: () {},
          child: const Text('PAGE CONTENT'),
        ),
      ),
    );

void main() {
  final basicActive = _ent('basic', 'active', ['core']);

  testWidgets('TEST-002: cashier menu hides settings, audit log and subscription', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(role: MemberRole.cashier, ent: basicActive, location: '/dashboard'));
    expect(find.byKey(const Key('menu-jobCards')), findsOneWidget);
    expect(find.byKey(const Key('menu-settings')), findsNothing);
    expect(find.byKey(const Key('menu-auditLog')), findsNothing);
    expect(find.byKey(const Key('menu-subscription')), findsNothing);
    expect(find.text('PAGE CONTENT'), findsOneWidget);
  });

  testWidgets('TEST-002: a role cannot open a page outside its menu', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(role: MemberRole.cashier, ent: basicActive, location: '/auditLog'));
    expect(find.text('PAGE CONTENT'), findsNothing);
    expect(find.text('You do not have access to this page.'), findsOneWidget);
  });

  testWidgets('TEST-006: Basic owner opening Bookings sees a locked card', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nav = <String>[];
    await tester.pumpWidget(_shell(role: MemberRole.owner, ent: basicActive, location: '/bookings', navLog: nav));
    expect(find.text('PAGE CONTENT'), findsNothing);
    expect(find.text('Available on Standard and Premium'), findsOneWidget);
    await tester.tap(find.text('Upgrade plan'));
    expect(nav, ['/subscription']);
  });

  testWidgets('TEST-009: read-only banner shows the PRD message', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(role: MemberRole.owner, ent: _ent('basic', 'read_only', ['core']), location: '/dashboard'));
    expect(find.textContaining('Subscription expired — read-only'), findsOneWidget);
  });

  testWidgets('TEST-007: trial banner shows days left', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(role: MemberRole.owner, ent: _ent('premium', 'trial', ['core', 'booking'], days: 2), location: '/dashboard'));
    expect(find.textContaining('Free trial'), findsOneWidget);
  });
}
