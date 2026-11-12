import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import 'widgets.dart';

/// Mobile + password login for station staff (SCR-030 and web login).
class StaffLoginForm extends StatefulWidget {
  const StaffLoginForm({super.key, required this.onSubmit, this.title = 'Log in', this.footer});
  final Future<void> Function(String mobile, String password) onSubmit;
  final String title;
  final Widget? footer;

  @override
  State<StaffLoginForm> createState() => _StaffLoginFormState();
}

class _StaffLoginFormState extends State<StaffLoginForm> {
  final _form = GlobalKey<FormState>();
  final _mobile = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _mobile.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await widget.onSubmit(_mobile.text, _password.text);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('mobile'),
          controller: _mobile,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Mobile', hintText: '0300-1234567'),
          validator: (v) => normalizePkMobile(v) == null ? 'Enter a mobile like 0300-1234567' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('password'),
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
          validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Log in'),
        ),
        if (widget.footer != null) ...[const SizedBox(height: 8), widget.footer!],
      ]),
    );
  }
}

/// Mobile then 6-digit code (customer login SCR-040, owner sign-up verification).
class OtpCodeForm extends StatefulWidget {
  const OtpCodeForm({super.key, required this.mobile, required this.onVerify, this.onResend});
  final String mobile;
  final Future<void> Function(String code) onVerify;
  final Future<void> Function()? onResend;

  @override
  State<OtpCodeForm> createState() => _OtpCodeFormState();
}

class _OtpCodeFormState extends State<OtpCodeForm> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (!RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      showError(context, const AppError(AppErrorCode.validation, 'Enter the 6-digit code'));
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.onVerify(_code.text);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = normalizePkMobile(widget.mobile);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Enter the code sent to ${m == null ? widget.mobile : formatPkMobile(m)}'),
      const SizedBox(height: 12),
      TextField(
        key: const Key('code'),
        controller: _code,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: const InputDecoration(labelText: '6-digit code'),
        onSubmitted: (_) => _verify(),
      ),
      FilledButton(onPressed: _busy ? null : _verify, child: const Text('Verify')),
      if (widget.onResend != null) TextButton(onPressed: _busy ? null : widget.onResend, child: const Text('Send code again')),
    ]);
  }
}
