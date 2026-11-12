import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';

/// REQ-002 — users and roles. Owner manages; manager can view.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  late Future<List<Member>> _members;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    setState(() => _members = s.api.members(s.current!.stationId));
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
    final isOwner = s.role == MemberRole.owner;
    return Scaffold(
      floatingActionButton: isOwner
          ? FloatingActionButton.extended(
              onPressed: () async {
                final added = await showDialog<bool>(context: context, builder: (_) => AddUserDialog(api: s.api, stationId: s.current!.stationId));
                if (added == true) _reload();
              },
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add user'),
            )
          : null,
      body: AsyncStateView<List<Member>>(
        future: _members,
        onRetry: _reload,
        builder: (context, members) => ListView(padding: const EdgeInsets.all(16), children: [
          Text('Users and roles', style: Theme.of(context).textTheme.titleLarge),
          for (final m in members)
            ListTile(
              leading: CircleAvatar(child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase())),
              title: Text(m.name, style: m.active ? null : const TextStyle(decoration: TextDecoration.lineThrough)),
              subtitle: Text('${m.mobile.isEmpty ? '' : formatPkMobile(m.mobile)} · ${m.active ? m.role.label : 'Deactivated'}'),
              trailing: !isOwner || m.role == MemberRole.owner
                  ? Text(m.role.label)
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      DropdownButton<MemberRole>(
                        value: m.role,
                        items: [MemberRole.manager, MemberRole.cashier, MemberRole.mechanic]
                            .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                            .toList(),
                        onChanged: m.active ? (r) => _run(() => s.api.setMemberRole(m.id, r!)) : null,
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _run(() => s.api.setMemberActive(m.id, !m.active)),
                        child: Text(m.active ? 'Deactivate' : 'Activate'),
                      ),
                    ]),
            ),
        ]),
      ),
    );
  }
}

class AddUserDialog extends StatefulWidget {
  const AddUserDialog({super.key, required this.api, required this.stationId});
  final StationApi api;
  final String stationId;

  @override
  State<AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends State<AddUserDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _mobile = TextEditingController();
  final _password = TextEditingController();
  MemberRole _role = MemberRole.mechanic;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _mobile.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await widget.api.inviteMember(widget.stationId, name: _name.text.trim(), mobile: _mobile.text, role: _role, password: _password.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add user'),
        content: Form(
          key: _form,
          child: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name'), validator: (v) => (v ?? '').trim().length < 2 ? 'Required' : null),
              const SizedBox(height: 12),
              TextFormField(
                controller: _mobile,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Mobile', hintText: '0300-1234567'),
                validator: (v) => normalizePkMobile(v) == null ? 'Enter a mobile like 0300-1234567' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<MemberRole>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [MemberRole.manager, MemberRole.cashier, MemberRole.mechanic]
                    .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                    .toList(),
                onChanged: (r) => setState(() => _role = r!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Initial password'),
                validator: (v) => (v ?? '').length < 8 ? 'At least 8 characters' : null,
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Add')),
        ],
      );
}
