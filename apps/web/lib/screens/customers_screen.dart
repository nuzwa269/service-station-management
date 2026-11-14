import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';

/// SCR-008 — customers and vehicles: search, profile, vehicles, history (REQ-046, REQ-048).
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _search = TextEditingController();
  Future<List<CustomerHit>>? _results;
  String? _selected;

  void _run() {
    final s = SessionScope.of(context);
    final q = _search.text.trim();
    setState(() => _results = q.length < 2 ? null : s.api.searchCustomers(s.current!.stationId, q));
  }

  Future<void> _addCustomer() async {
    final id = await showDialog<String>(context: context, builder: (_) => const CustomerDialog());
    if (id != null) setState(() => _selected = id);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: 'Customers & vehicles', actions: [
        FilledButton.icon(onPressed: _addCustomer, icon: const Icon(Icons.person_add_alt), label: const Text('Add customer')),
      ]),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _search,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Phone, plate or name'),
          onChanged: (_) => _run(),
        ),
      ),
      Expanded(
        child: _results == null
            ? const Center(child: Text('Search by phone, number plate or name'))
            : AsyncStateView<List<CustomerHit>>(
                future: _results!,
                isEmpty: (l) => l.isEmpty,
                emptyText: 'No customer found — Add customer',
                builder: (context, hits) => ListView(children: [
                  for (final h in hits)
                    ListTile(
                      selected: h.customerId == _selected,
                      leading: Icon(h.plate == null ? Icons.person_outline : Icons.directions_car_outlined),
                      title: Text(h.plate == null ? h.name : '${h.plate} · ${h.name}'),
                      subtitle: Text([formatPkMobile(h.mobile), if (h.make != null) '${h.make} ${h.model ?? ''}'].join(' · ')),
                      onTap: () => setState(() => _selected = h.customerId),
                    ),
                ]),
              ),
      ),
    ]);
    final detail = _selected == null
        ? const Center(child: Text('Select a customer'))
        : CustomerDetail(key: ValueKey(_selected), customerId: _selected!, onChanged: _run);
    if (wide) {
      return Row(children: [Expanded(flex: 2, child: list), const VerticalDivider(width: 1), Expanded(flex: 3, child: detail)]);
    }
    return _selected == null
        ? list
        : Column(children: [
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => setState(() => _selected = null), icon: const Icon(Icons.arrow_back), label: const Text('Back'))),
            Expanded(child: detail),
          ]);
  }
}

class CustomerDetail extends StatefulWidget {
  const CustomerDetail({super.key, required this.customerId, required this.onChanged});
  final String customerId;
  final VoidCallback onChanged;

  @override
  State<CustomerDetail> createState() => _CustomerDetailState();
}

class _CustomerDetailState extends State<CustomerDetail> {
  late Future<Map<String, dynamic>> _customer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() => setState(() => _customer = SessionScope.of(context).api.customer(widget.customerId));

  Future<void> _editCustomer(Map<String, dynamic> c) async {
    final id = await showDialog<String>(context: context, builder: (_) => CustomerDialog(existing: c));
    if (id != null) {
      _reload();
      widget.onChanged();
    }
  }

  Future<void> _editVehicle([Map<String, dynamic>? v]) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => VehicleDialog(customerId: widget.customerId, existing: v));
    if (ok == true) {
      _reload();
      widget.onChanged();
    }
  }

  Future<void> _history(Map<String, dynamic> v) async {
    final api = SessionScope.of(context).api;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${v['plate']} — service history'),
        content: SizedBox(
          width: 480,
          height: 360,
          child: AsyncStateView<List<Map<String, dynamic>>>(
            future: api.vehicleHistory(v['id'] as String),
            isEmpty: (l) => l.isEmpty,
            builder: (context, rows) => ListView(children: [
              for (final r in rows)
                ListTile(
                  dense: true,
                  title: Text(r['title'] as String),
                  subtitle: Text(formatDate(DateTime.parse(r['at'] as String).toLocal())),
                ),
              const ListTile(dense: true, subtitle: Text('Jobs, parts and invoices appear here once job cards are in use (Phase 3–4).')),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AsyncStateView<Map<String, dynamic>>(
        future: _customer,
        onRetry: _reload,
        builder: (context, c) {
          final vehicles = (c['vehicles'] as List).cast<Map<String, dynamic>>();
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Expanded(child: Text(c['name'] as String, style: Theme.of(context).textTheme.headlineSmall)),
              IconButton(tooltip: 'Edit', onPressed: () => _editCustomer(c), icon: const Icon(Icons.edit_outlined)),
            ]),
            Text([formatPkMobile(c['mobile'] as String), if (c['email'] != null) c['email'], if (c['address'] != null) c['address']].join(' · ')),
            const Divider(height: 32),
            Row(children: [
              Expanded(child: Text('Vehicles', style: Theme.of(context).textTheme.titleMedium)),
              TextButton.icon(onPressed: _editVehicle, icon: const Icon(Icons.add), label: const Text('Add vehicle')),
            ]),
            if (vehicles.isEmpty) const Text('No vehicles yet'),
            for (final v in vehicles)
              ListTile(
                leading: const Icon(Icons.directions_car_outlined),
                title: Text(v['plate'] as String),
                subtitle: Text([v['make'], v['model'], v['year'], v['colour']].whereType<Object>().join(' · ')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(onPressed: () => _history(v), child: const Text('History')),
                  IconButton(tooltip: 'Edit / change owner', onPressed: () => _editVehicle(v), icon: const Icon(Icons.edit_outlined)),
                ]),
              ),
            const Divider(height: 32),
            CustomerDuesCard(customerId: widget.customerId),
          ]);
        },
      );
}

class CustomerDialog extends StatefulWidget {
  const CustomerDialog({super.key, this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<CustomerDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?['name'] as String?);
  late final _mobile = TextEditingController(text: widget.existing == null ? '' : formatPkMobile(widget.existing!['mobile'] as String));
  late final _email = TextEditingController(text: widget.existing?['email'] as String?);
  late final _address = TextEditingController(text: widget.existing?['address'] as String?);

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add customer' : 'Edit customer'),
      content: Form(
        key: _form,
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name'), validator: (v) => (v ?? '').trim().length < 2 ? 'Name missing' : null),
            const SizedBox(height: 12),
            TextFormField(
              controller: _mobile,
              decoration: const InputDecoration(labelText: 'Mobile', hintText: '0300-1234567'),
              validator: (v) => normalizePkMobile(v) == null ? 'Enter a mobile like 0300-1234567' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(controller: _email, decoration: const InputDecoration(labelText: 'Email (optional)')),
            const SizedBox(height: 12),
            TextFormField(controller: _address, decoration: const InputDecoration(labelText: 'Address (optional)')),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            if (!_form.currentState!.validate()) return;
            String? id;
            final ok = await runAction(context, () async {
              id = await s.api.saveCustomer(s.current!.stationId,
                  id: widget.existing?['id'] as String?, name: _name.text, mobile: _mobile.text, email: _email.text, address: _address.text);
            });
            if (ok && context.mounted) Navigator.pop(context, id);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class VehicleDialog extends StatefulWidget {
  const VehicleDialog({super.key, required this.customerId, this.existing});
  final String customerId;
  final Map<String, dynamic>? existing;

  @override
  State<VehicleDialog> createState() => _VehicleDialogState();
}

class _VehicleDialogState extends State<VehicleDialog> {
  final _form = GlobalKey<FormState>();
  late final _plate = TextEditingController(text: widget.existing?['plate'] as String?);
  late final _make = TextEditingController(text: widget.existing?['make'] as String?);
  late final _model = TextEditingController(text: widget.existing?['model'] as String?);
  late final _year = TextEditingController(text: widget.existing?['year']?.toString());
  late final _colour = TextEditingController(text: widget.existing?['colour'] as String?);
  final _newOwnerMobile = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add vehicle' : 'Edit vehicle'),
      content: Form(
        key: _form,
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _plate,
              decoration: const InputDecoration(labelText: 'Number plate', hintText: 'LEA-1234'),
              validator: (v) => normalizePlate(v) == null ? 'Enter a plate like LEA-1234' : null,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextFormField(controller: _make, decoration: const InputDecoration(labelText: 'Make'))),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(controller: _model, decoration: const InputDecoration(labelText: 'Model'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: _year,
                  decoration: const InputDecoration(labelText: 'Year'),
                  validator: (v) => (v ?? '').isEmpty || (int.tryParse(v!) ?? 0) > 1950 ? null : 'Year like 2018',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(controller: _colour, decoration: const InputDecoration(labelText: 'Colour'))),
            ]),
            if (widget.existing != null) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _newOwnerMobile,
                decoration: const InputDecoration(labelText: 'Move to another customer (their mobile, optional)'),
                validator: (v) => (v ?? '').trim().isEmpty || normalizePkMobile(v) != null ? null : 'Enter a mobile like 0300-1234567',
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            if (!_form.currentState!.validate()) return;
            final ok = await runAction(context, () async {
              var owner = widget.customerId;
              final newMobile = normalizePkMobile(_newOwnerMobile.text);
              if (newMobile != null) {
                final hits = await s.api.searchCustomers(s.current!.stationId, newMobile);
                final match = hits.where((h) => h.mobile == newMobile).toList();
                if (match.isEmpty) throw const AppError(AppErrorCode.notFound, 'No customer with that mobile — add them first');
                owner = match.first.customerId;
              }
              await s.api.saveVehicle(s.current!.stationId,
                  id: widget.existing?['id'] as String?,
                  customerId: owner,
                  plate: _plate.text,
                  make: _make.text,
                  model: _model.text,
                  year: int.tryParse(_year.text),
                  colour: _colour.text);
            });
            if (ok && context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// REQ-040 — dues (oldest first) and credit balance, with "Collect dues".
class CustomerDuesCard extends StatefulWidget {
  const CustomerDuesCard({super.key, required this.customerId});
  final String customerId;

  @override
  State<CustomerDuesCard> createState() => _CustomerDuesCardState();
}

class _CustomerDuesCardState extends State<CustomerDuesCard> {
  late Future<({Money dues, Money credit})> _bal;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bal = SessionScope.of(context).api.customerBalance(widget.customerId);
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.of(context).api;
    return FutureBuilder<({Money dues, Money credit})>(
      future: _bal,
      builder: (context, snap) {
        final b = snap.data;
        if (b == null) return const SizedBox(height: 40);
        return Row(children: [
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Dues'),
                  Text(formatPkr(b.dues), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: b.dues.paisa > 0 ? const Color(0xFFDC2626) : null)),
                  if (b.dues.paisa > 0)
                    TextButton(
                      onPressed: () async {
                        final amount = TextEditingController(text: '${b.dues.wholeRupees}');
                        final ref = TextEditingController();
                        var method = PayMethod.cash;
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => StatefulBuilder(
                            builder: (ctx, set) => AlertDialog(
                              title: const Text('Collect dues'),
                              content: Column(mainAxisSize: MainAxisSize.min, children: [
                                Text('Oldest invoice is cleared first. Dues: ${formatPkr(b.dues)}'),
                                const SizedBox(height: 12),
                                TextField(controller: amount, decoration: const InputDecoration(labelText: 'Amount (Rs)')),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<PayMethod>(
                                  initialValue: method,
                                  items: [for (final m in PayMethod.receivable) DropdownMenuItem(value: m, child: Text(m.label))],
                                  onChanged: (m) => set(() => method = m!),
                                ),
                                if (method.needsReference) TextField(controller: ref, decoration: const InputDecoration(labelText: 'Reference number')),
                              ]),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Collect')),
                              ],
                            ),
                          ),
                        );
                        final m = parsePkr(amount.text);
                        if (ok != true || m == null || !context.mounted) return;
                        if (await runAction(context, () => api.collectDues(widget.customerId, m, method, reference: ref.text), success: 'Dues collected')) {
                          setState(() => _bal = api.customerBalance(widget.customerId));
                        }
                      },
                      child: const Text('Collect dues'),
                    ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Credit'),
                  Text(formatPkr(b.credit), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF16A34A))),
                  const Text('Used from the invoice screen', style: TextStyle(fontSize: 12)),
                ]),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
