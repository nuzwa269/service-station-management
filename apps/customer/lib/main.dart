import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Customer app (Android 8+): phone + one-time code login (REQ-047).
/// Linked stations, booking and approvals arrive in Phase 6.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initBackend();
  runApp(MaterialApp(
    title: 'My Car Service',
    theme: appTheme(),
    debugShowCheckedModeBanner: false,
    home: AppConfig.isConfigured ? CustomerRoot(api: StationApi(Supabase.instance.client)) : const MissingConfigScreen(),
  ));
}

class CustomerRoot extends StatelessWidget {
  const CustomerRoot({super.key, required this.api});
  final StationApi api;

  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
        stream: api.client.auth.onAuthStateChange,
        builder: (context, _) {
          if (api.client.auth.currentSession == null) return CustomerLoginScreen(api: api);
          return Scaffold(
            appBar: AppBar(
              title: const Text('My vehicles & stations'),
              actions: [IconButton(tooltip: 'Log out', onPressed: api.signOut, icon: const Icon(Icons.logout))],
            ),
            body: const PlannedScreen(title: 'Linked stations, booking and approvals', phase: 'Phase 6 (TASK-054…058)'),
          );
        },
      );
}

/// SCR-040 — phone number, then the 6-digit code.
class CustomerLoginScreen extends StatefulWidget {
  const CustomerLoginScreen({super.key, required this.api});
  final StationApi api;

  @override
  State<CustomerLoginScreen> createState() => _CustomerLoginScreenState();
}

class _CustomerLoginScreenState extends State<CustomerLoginScreen> {
  final _mobile = TextEditingController();
  bool _sent = false;
  bool _busy = false;

  @override
  void dispose() {
    _mobile.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await widget.api.sendCustomerCode(_mobile.text);
      setState(() => _sent = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: _sent
                  ? OtpCodeForm(
                      mobile: _mobile.text,
                      onVerify: (code) => widget.api.verifyCustomerCode(_mobile.text, code),
                      onResend: () => widget.api.sendCustomerCode(_mobile.text),
                    )
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('Log in', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('mobile'),
                        controller: _mobile,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'Mobile', hintText: '0300-1234567'),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _busy ? null : _send, child: const Text('Send code')),
                    ]),
            ),
          ),
        ),
      );
}
