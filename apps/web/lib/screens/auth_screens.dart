import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'settings_screen.dart';

class _CenteredCard extends StatelessWidget {
  const _CenteredCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(child: Padding(padding: const EdgeInsets.all(24), child: child)),
            ),
          ),
        ),
      );
}

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return _CenteredCard(
      child: StaffLoginForm(
        title: 'Service Station — Log in',
        onSubmit: (m, p) => session.api.signInStaff(m, p),
        footer: TextButton(onPressed: () => context.go('/signup'), child: const Text('New station? Start 14-day free trial')),
      ),
    );
  }
}

/// SCR-001 — REQ-001 station self sign-up with a verified mobile.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _form = GlobalKey<FormState>();
  final _owner = TextEditingController();
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _station = TextEditingController();
  final _city = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_owner, _mobile, _email, _password, _station, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await SessionScope.of(context).api.signUpOwner(_mobile.text, _password.text);
      setState(() => _codeSent = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify(String code) async {
    final session = SessionScope.of(context);
    await session.api.verifySignupCode(_mobile.text, code);
    await session.api.createStation(
      stationName: _station.text.trim(),
      city: _city.text.trim(),
      ownerName: _owner.text.trim(),
      email: _email.text.trim().isEmpty ? null : _email.text.trim(),
    );
    await session.load();
    if (mounted) context.go('/onboarding');
  }

  String? _required(String? v, String label) => (v ?? '').trim().length < 2 ? '$label is required' : null;

  @override
  Widget build(BuildContext context) {
    if (_codeSent) {
      return _CenteredCard(
        child: OtpCodeForm(mobile: _mobile.text, onVerify: _verify, onResend: () => SessionScope.of(context).api.signUpOwner(_mobile.text, _password.text)),
      );
    }
    return _CenteredCard(
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Start your free trial', style: Theme.of(context).textTheme.headlineSmall),
          const Text('14 days with all Premium features. No payment needed.'),
          const SizedBox(height: 16),
          TextFormField(controller: _owner, decoration: const InputDecoration(labelText: 'Your name'), validator: (v) => _required(v, 'Name')),
          const SizedBox(height: 12),
          TextFormField(
            controller: _mobile,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Mobile', hintText: '0300-1234567'),
            validator: (v) => normalizePkMobile(v) == null ? 'Enter a mobile like 0300-1234567' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email (optional)'),
            validator: (v) => (v ?? '').isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!) ? null : 'Enter a valid email',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password (min 8 characters)'),
            validator: (v) => (v ?? '').length < 8 ? 'At least 8 characters' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(controller: _station, decoration: const InputDecoration(labelText: 'Station name'), validator: (v) => _required(v, 'Station name')),
          const SizedBox(height: 12),
          TextFormField(controller: _city, decoration: const InputDecoration(labelText: 'City'), validator: (v) => _required(v, 'City')),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _sendCode, child: const Text('Send verification code')),
          TextButton(onPressed: () => context.go('/login'), child: const Text('Already registered? Log in')),
        ]),
      ),
    );
  }
}

/// SCR-002 — onboarding: branding and tax, then into the dashboard.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Set up your station')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              const Text('Add your logo and tax details. You can change these later in Settings.'),
              const SizedBox(height: 16),
              StationProfileForm(onSaved: () => context.go('/dashboard')),
              TextButton(onPressed: () => context.go('/dashboard'), child: const Text('Skip for now')),
            ]),
          ),
        ),
      );
}

class NoStationScreen extends StatelessWidget {
  const NoStationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return _CenteredCard(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (session.error != null) ErrorStateView(message: session.error!.message, onRetry: session.load)
        else const Text('Your account is not active in any station. Ask the station owner to activate it.', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: session.signOut, child: const Text('Log out')),
      ]),
    );
  }
}
