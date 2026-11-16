import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'gateway.dart';

/// Platform SMS gateway (TASK-005): a dedicated Android phone with a SIM and SMS bundle,
/// kept on the charger with this app open. It sends login codes queued by Supabase Auth.
void main() => runApp(const MaterialApp(title: 'SMS Gateway', debugShowCheckedModeBanner: false, home: GatewayHome()));

const _sms = MethodChannel('pk.servicestation/sms');

Future<String?> sendFromSim(String phone, String body) async {
  try {
    return await _sms.invokeMethod<String?>('send', {'phone': phone, 'body': body});
  } on PlatformException catch (e) {
    return e.message ?? e.code;
  }
}

/// Default server from the build config (--dart-define-from-file); can be changed on the phone.
const _defaultUrl = String.fromEnvironment('SUPABASE_URL');

class GatewayHome extends StatefulWidget {
  const GatewayHome({super.key});

  @override
  State<GatewayHome> createState() => _GatewayHomeState();
}

class _GatewayHomeState extends State<GatewayHome> {
  final _url = TextEditingController();
  final _secret = TextEditingController();
  final _events = <GatewayEvent>[];
  GatewayLoop? _loop;
  bool _permission = false;
  bool _showSecret = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _url.text = p.getString('url') ?? (_defaultUrl.isEmpty ? '' : _defaultUrl);
    _secret.text = p.getString('secret') ?? '';
    _permission = await _sms.invokeMethod<bool>('hasPermission') ?? false;
    setState(() {});
    if (_permission && _secret.text.length >= 24 && (p.getBool('running') ?? false)) _start();
  }

  Future<void> _askPermission() async {
    _permission = await _sms.invokeMethod<bool>('requestPermission') ?? false;
    setState(() {});
  }

  Future<void> _start() async {
    final base = _url.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (!base.startsWith('https://') || _secret.text.trim().length < 24) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter the server address and the gateway secret')));
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('url', base);
    await p.setString('secret', _secret.text.trim());
    await p.setBool('running', true);
    final device = await _sms.invokeMethod<String>('deviceName') ?? 'gateway';
    _loop?.stop();
    _loop = GatewayLoop(
      server: GatewayServer(functionUrl: '$base/functions/v1/sms-gateway', secret: _secret.text.trim(), device: device),
      send: sendFromSim,
      onEvent: (e) => setState(() {
        _events.insert(0, e);
        if (_events.length > 50) _events.removeLast();
      }),
    )..start();
    await WakelockPlus.enable();
    setState(() {});
    _tick();
  }

  // Refresh the status line every few seconds while running.
  Future<void> _tick() async {
    while (mounted && (_loop?.running ?? false)) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (mounted) setState(() {});
    }
  }

  Future<void> _stop() async {
    _loop?.stop();
    final p = await SharedPreferences.getInstance();
    await p.setBool('running', false);
    await WakelockPlus.disable();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loop = _loop;
    final running = loop?.running ?? false;
    final healthy = running && loop!.lastError == null && loop.lastContact != null;
    final color = !running ? Colors.grey : (healthy ? Colors.green : Colors.orange);
    return Scaffold(
      appBar: AppBar(title: const Text('SMS Gateway')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.circle, color: color, size: 14),
                const SizedBox(width: 8),
                Text(!running ? 'Stopped' : (healthy ? 'Running — waiting for codes' : 'Running — cannot reach server'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ]),
              if (running && loop!.lastError != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(loop.lastError!)),
              const SizedBox(height: 8),
              Text('Sent: ${loop?.sent ?? 0}    Failed: ${loop?.failed ?? 0}'),
              const SizedBox(height: 8),
              const Text('Keep this phone on the charger, with Wi-Fi or data on and this app open. '
                  'Codes older than 5 minutes are not sent.', style: TextStyle(fontSize: 12)),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        if (!_permission)
          FilledButton.icon(onPressed: _askPermission, icon: const Icon(Icons.sms), label: const Text('Allow sending SMS'))
        else ...[
          TextField(
            controller: _url,
            enabled: !running,
            decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://xxxx.supabase.co'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secret,
            enabled: !running,
            obscureText: !_showSecret,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Gateway secret',
              suffixIcon: IconButton(
                icon: Icon(_showSecret ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() { _showSecret = !_showSecret; }),
              ),
            ),
          ),
          const SizedBox(height: 12),
          running
              ? OutlinedButton.icon(onPressed: _stop, icon: const Icon(Icons.stop), label: const Text('Stop'))
              : FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_arrow), label: const Text('Start')),
        ],
        const SizedBox(height: 16),
        const Text('Recent', style: TextStyle(fontWeight: FontWeight.w700)),
        if (_events.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing sent yet')),
        for (final e in _events)
          ListTile(
            dense: true,
            leading: Icon(e.ok ? Icons.check_circle : Icons.error, color: e.ok ? Colors.green : Colors.red),
            title: Text(e.text),
            subtitle: Text('${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}:${e.at.second.toString().padLeft(2, '0')}'),
          ),
      ]),
    );
  }
}
