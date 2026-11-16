import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One message the server wants sent.
class SmsJob {
  const SmsJob(this.id, this.phone, this.body);
  final int id;
  final String phone;
  final String body;
}

/// Sends one SMS from the phone's SIM; returns null on success or an error text.
typedef SmsSender = Future<String?> Function(String phone, String body);

/// Talks to the sms-gateway Edge Function.
class GatewayServer {
  GatewayServer({required this.functionUrl, required this.secret, required this.device, http.Client? client})
      : _http = client ?? http.Client();

  final String functionUrl; // https://<project>.supabase.co/functions/v1/sms-gateway
  final String secret;
  final String device;
  final http.Client _http;

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final res = await _http
        .post(Uri.parse(functionUrl), headers: {'content-type': 'application/json', 'x-gateway-secret': secret}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 403) throw const GatewayError('Wrong gateway secret');
    if (res.statusCode != 200) throw GatewayError('Server error ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<SmsJob>> claim({Map<String, dynamic> info = const {}}) async {
    final r = await _post({'action': 'claim', 'device': device, 'info': info});
    return [
      for (final m in (r['messages'] as List? ?? const []))
        SmsJob((m['id'] as num).toInt(), m['phone'] as String, m['body'] as String),
    ];
  }

  Future<void> report(int id, {required bool ok, String? error}) => _post({'action': 'report', 'id': id, 'ok': ok, 'error': error});
}

class GatewayError implements Exception {
  const GatewayError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What happened, for the on-screen log (numbers are masked).
class GatewayEvent {
  const GatewayEvent(this.at, this.text, {this.ok = true});
  final DateTime at;
  final String text;
  final bool ok;
}

String maskPhone(String phone) => phone.length <= 6 ? phone : '${phone.substring(0, phone.length - 7)}•••${phone.substring(phone.length - 4)}';

/// Polls the server and sends what it gets. One round = claim → send each → report each.
class GatewayLoop {
  GatewayLoop({required this.server, required this.send, this.interval = const Duration(seconds: 4), this.onEvent});

  final GatewayServer server;
  final SmsSender send;
  final Duration interval;
  final void Function(GatewayEvent e)? onEvent;

  int sent = 0;
  int failed = 0;
  String? lastError;
  DateTime? lastContact;
  Timer? _timer;
  bool _busy = false;

  bool get running => _timer != null;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => round());
    round();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one claim/send/report round. Public for tests.
  Future<void> round() async {
    if (_busy) return;
    _busy = true;
    try {
      final jobs = await server.claim(info: {'sent': sent, 'failed': failed});
      lastContact = DateTime.now();
      lastError = null;
      for (final j in jobs) {
        final err = await send(j.phone, j.body);
        if (err == null) {
          sent++;
          onEvent?.call(GatewayEvent(DateTime.now(), 'Sent to ${maskPhone(j.phone)}'));
        } else {
          failed++;
          onEvent?.call(GatewayEvent(DateTime.now(), 'Failed ${maskPhone(j.phone)}: $err', ok: false));
        }
        await server.report(j.id, ok: err == null, error: err);
      }
    } catch (e) {
      lastError = e.toString();
    } finally {
      _busy = false;
    }
  }
}
