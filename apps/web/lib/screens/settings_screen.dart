import 'package:app_shared/app_shared.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';

/// SCR-017 — station rules. This phase: profile, branding, tax (REQ-004),
/// users link (REQ-002) and support access (REQ-005).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final role = SessionScope.of(context).role;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Station profile and tax', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      StationProfileForm(readOnly: role != MemberRole.owner),
      if (role == MemberRole.owner) ...[
        const Divider(height: 32),
        const JobSettingsSection(),
        const Divider(height: 32),
        const SupportAccessSection(),
      ],
    ]);
  }
}

class StationProfileForm extends StatefulWidget {
  const StationProfileForm({super.key, this.readOnly = false, this.onSaved});
  final bool readOnly;
  final VoidCallback? onSaved;

  @override
  State<StationProfileForm> createState() => _StationProfileFormState();
}

class _StationProfileFormState extends State<StationProfileForm> {
  final _form = GlobalKey<FormState>();
  final _c = {for (final k in ['name', 'address', 'phone', 'ntn', 'strn', 'parts_tax_pct', 'services_tax_pct']) k: TextEditingController()};
  bool _taxOn = false;
  String? _logoPath;
  bool _loaded = false;
  bool _busy = false;
  AppError? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) _load();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final s = await session.api.station(session.current!.stationId);
      for (final k in _c.keys) {
        _c[k]!.text = s[k]?.toString() ?? '';
      }
      _taxOn = s['sales_tax_enabled'] as bool? ?? false;
      _logoPath = s['logo_path'] as String?;
      _error = null;
    } on AppError catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _pct(String? v) {
    final n = num.tryParse((v ?? '').trim().isEmpty ? '0' : v!.trim());
    if (n == null || n < 0 || n > 100) return '0–100';
    if (RegExp(r'\.\d{3,}$').hasMatch(v!.trim())) return 'Max 2 decimals';
    return null;
  }

  Future<void> _pickLogo() async {
    final session = SessionScope.of(context);
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg']);
    if (f == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await f.readAsBytes();
      final ext = f.name.split('.').last;
      final path = await session.api.uploadLogo(session.current!.stationId, bytes, ext);
      setState(() => _logoPath = path);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final session = SessionScope.of(context);
    setState(() => _busy = true);
    try {
      await session.api.updateProfile(session.current!.stationId, {
        'name': _c['name']!.text,
        'address': _c['address']!.text,
        'phone': _c['phone']!.text,
        'ntn': _c['ntn']!.text,
        'strn': _c['strn']!.text,
        'sales_tax_enabled': _taxOn,
        'parts_tax_pct': num.tryParse(_c['parts_tax_pct']!.text) ?? 0,
        'services_tax_pct': num.tryParse(_c['services_tax_pct']!.text) ?? 0,
        'logo_path': _logoPath,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
      widget.onSaved?.call();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String key, String label, {String? Function(String?)? validator, TextInputType? keyboard}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: _c[key],
          enabled: !widget.readOnly,
          keyboardType: keyboard,
          decoration: InputDecoration(labelText: label),
          validator: validator,
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    if (_error != null) return ErrorStateView(message: _error!.message, onRetry: _load);
    final api = SessionScope.of(context).api;
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CircleAvatar(
            radius: 32,
            backgroundImage: _logoPath == null ? null : NetworkImage(api.logoUrl(_logoPath!)),
            child: _logoPath == null ? const Icon(Icons.store_outlined) : null,
          ),
          const SizedBox(width: 16),
          if (!widget.readOnly)
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickLogo,
              icon: const Icon(Icons.upload_outlined),
              label: const Text('Logo (PNG/JPG, max 2 MB)'),
            ),
        ]),
        const SizedBox(height: 16),
        _field('name', 'Station name', validator: (v) => (v ?? '').trim().length < 2 ? 'Required' : null),
        _field('address', 'Address'),
        _field('phone', 'Station phone', keyboard: TextInputType.phone),
        _field('ntn', 'NTN (optional)'),
        _field('strn', 'STRN (optional)'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Charge sales tax'),
          subtitle: const Text('Tax lines print on invoices only when on'),
          value: _taxOn,
          onChanged: widget.readOnly ? null : (v) => setState(() => _taxOn = v),
        ),
        Row(children: [
          Expanded(child: _field('parts_tax_pct', 'Parts tax %', validator: _pct, keyboard: TextInputType.number)),
          const SizedBox(width: 12),
          Expanded(child: _field('services_tax_pct', 'Services tax %', validator: _pct, keyboard: TextInputType.number)),
        ]),
        if (!widget.readOnly) FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ]),
    );
  }
}

/// REQ-005 — owner grants the platform team 1 / 24 / 72 hours of read-only access.
class SupportAccessSection extends StatefulWidget {
  const SupportAccessSection({super.key});

  @override
  State<SupportAccessSection> createState() => _SupportAccessSectionState();
}

class _SupportAccessSectionState extends State<SupportAccessSection> {
  late Future<List<Map<String, dynamic>>> _grants;
  int _hours = 24;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    setState(() => _grants = s.api.supportGrants(s.current!.stationId));
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Support access', style: Theme.of(context).textTheme.titleMedium),
      const Text('Let the platform team view your station (read-only) to help you. Every view is logged.'),
      const SizedBox(height: 8),
      Row(children: [
        DropdownButton<int>(
          value: _hours,
          items: const [1, 24, 72].map((h) => DropdownMenuItem(value: h, child: Text('$h hours'))).toList(),
          onChanged: (v) => setState(() => _hours = v!),
        ),
        const SizedBox(width: 12),
        FilledButton.tonal(
          onPressed: () => _run(() => s.api.grantSupport(s.current!.stationId, _hours)),
          child: const Text('Grant support access'),
        ),
      ]),
      AsyncStateView<List<Map<String, dynamic>>>(
        future: _grants,
        onRetry: _reload,
        builder: (context, rows) {
          final now = DateTime.now();
          return Column(children: [
            for (final g in rows)
              () {
                final expires = DateTime.parse(g['expires_at'] as String).toLocal();
                final active = g['revoked_at'] == null && expires.isAfter(now);
                return ListTile(
                  dense: true,
                  title: Text(active ? 'Active until ${formatDate(expires)} ${formatTime(expires)}' : 'Ended'),
                  subtitle: Text('Granted ${formatDate(DateTime.parse(g['starts_at'] as String).toLocal())}'),
                  trailing: active ? TextButton(onPressed: () => _run(() => s.api.revokeSupport(g['id'] as String)), child: const Text('Revoke')) : null,
                );
              }(),
          ]);
        },
      ),
    ]);
  }
}

/// REQ-019 checklist template and REQ-025 inspection fee (owner).
class JobSettingsSection extends StatefulWidget {
  const JobSettingsSection({super.key});

  @override
  State<JobSettingsSection> createState() => _JobSettingsSectionState();
}

class _JobSettingsSectionState extends State<JobSettingsSection> {
  final _items = TextEditingController();
  final _fee = TextEditingController();
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    s.api.checklistTemplate(id).then((names) {
      if (mounted) _items.text = names.join('\n');
    });
    s.api.station(id).then((st) {
      if (mounted) _fee.text = (((st['inspection_fee_paisa'] as num?) ?? 0) / 100).toStringAsFixed(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Job cards', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      const Text('Checklist items are copied onto every new job card. One item per line.'),
      const SizedBox(height: 12),
      TextField(
        controller: _items,
        minLines: 4,
        maxLines: 10,
        decoration: const InputDecoration(labelText: 'Inspection checklist', hintText: 'Brake pads\nTyres\nLights\nBattery\nFluids'),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: 260,
        child: TextField(
          controller: _fee,
          decoration: const InputDecoration(labelText: 'Inspection fee (Rs)', helperText: 'Charged when a job is cancelled or rejected'),
        ),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: () async {
            final id = s.current!.stationId;
            final names = _items.text.split('\n').map((e) => e.trim()).where((e) => e.length >= 2).toList();
            final fee = parsePkr(_fee.text.isEmpty ? '0' : _fee.text);
            if (fee == null) return;
            await runAction(context, () async {
              await s.api.saveChecklistTemplate(id, names);
              await s.api.setInspectionFee(id, fee);
            }, success: 'Saved');
          },
          child: const Text('Save job settings'),
        ),
      ),
    ]);
  }
}
