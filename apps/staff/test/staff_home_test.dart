import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:staff_app/main.dart';
import 'package:station_core/station_core.dart';

void main() {
  final ent = Entitlements.fromRow({
    'plan_code': 'basic',
    'effective_plan': 'basic',
    'status': 'active',
    'features': ['core'],
    'renews_at': null,
  });

  Widget home(MemberRole role) => MaterialApp(
        theme: appTheme(),
        home: StaffHome(stationName: 'Delta', role: role, entitlements: ent, onSignOut: () {}),
      );

  testWidgets('mechanic lands on My jobs (SCR-031)', (tester) async {
    await tester.pumpWidget(home(MemberRole.mechanic));
    expect(find.text('My jobs'), findsOneWidget);
  });

  testWidgets('cashier lands on the quick dashboard (SCR-035)', (tester) async {
    await tester.pumpWidget(home(MemberRole.cashier));
    expect(find.text('Delta'), findsOneWidget);
    expect(find.textContaining('Quick dashboard'), findsOneWidget);
  });

  testWidgets('staff login validates Pakistani mobile', (tester) async {
    var submitted = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StaffLoginForm(onSubmit: (_, _) async => submitted = true)),
    ));
    await tester.enterText(find.byKey(const Key('mobile')), '12345');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.tap(find.text('Log in').last);
    await tester.pump();
    expect(find.text('Enter a mobile like 0300-1234567'), findsOneWidget);
    expect(submitted, isFalse);

    await tester.enterText(find.byKey(const Key('mobile')), '0300-1234567');
    await tester.tap(find.text('Log in').last);
    await tester.pump();
    expect(submitted, isTrue);
  });
}
