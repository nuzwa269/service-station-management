import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sms_gateway/gateway.dart';

void main() {
  test('one round: claim, send from SIM, report each result', () async {
    final reports = <Map<String, dynamic>>[];
    String? secretSeen;
    final client = MockClient((req) async {
      secretSeen = req.headers['x-gateway-secret'];
      final b = jsonDecode(req.body) as Map<String, dynamic>;
      if (b['action'] == 'claim') {
        return http.Response(jsonEncode({'messages': [
          {'id': 1, 'phone': '+923001234567', 'body': '123456 is your code'},
          {'id': 2, 'phone': '+923009999999', 'body': '654321 is your code'},
        ]}), 200);
      }
      reports.add(b);
      return http.Response('{"ok":true}', 200);
    });
    final sent = <String>[];
    final loop = GatewayLoop(
      server: GatewayServer(functionUrl: 'https://x.supabase.co/functions/v1/sms-gateway', secret: 's' * 32, device: 'test', client: client),
      send: (phone, body) async {
        sent.add(phone);
        return phone.endsWith('9999') ? 'No signal' : null;
      },
    );
    await loop.round();
    expect(secretSeen, 's' * 32);
    expect(sent, ['+923001234567', '+923009999999']);
    expect(loop.sent, 1);
    expect(loop.failed, 1);
    expect(reports.map((r) => [r['id'], r['ok'], r['error']]).toList(), [[1, true, null], [2, false, 'No signal']]);
  });

  test('wrong secret shows a clear error and sends nothing', () async {
    final loop = GatewayLoop(
      server: GatewayServer(functionUrl: 'https://x/fn', secret: 'bad', device: 't', client: MockClient((_) async => http.Response('', 403))),
      send: (_, _) async => fail('must not send'),
    );
    await loop.round();
    expect(loop.lastError, 'Wrong gateway secret');
  });

  test('phone numbers are masked in the on-screen log', () {
    expect(maskPhone('+923001234567'), '+92300•••4567');
  });
}
