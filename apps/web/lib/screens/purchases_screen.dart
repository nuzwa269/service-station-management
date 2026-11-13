import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';

/// SCR-010 — supplier bills (REQ-029), suppliers and ledger (REQ-030, Standard+).
class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key});

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  late Future<List<Purchase>> _purchases;
  late Future<List<Supplier>> _suppliers;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  bool get _hasLedger => SessionScope.of(context).entitlements!.has(Feature.supplierLedger);

  void _reload() {
    final s = SessionScope.of(context);
    setState(() {
      _purchases = s.api.purchases(s.current!.stationId);
      _suppliers = _hasLedger ? s.api.suppliers(s.current!.stationId) : Future.value(const []);
    });
  }

  Future<void> _newBill() async {
    final s = SessionScope.of(context);
    final items = await s.api.items(s.current!.stationId);
    final suppliers = await _suppliers;
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => PurchaseDialog(items: items.where((i) => i.active && i.unit != ItemUnit.kit).toList(), suppliers: suppliers, useSupplierList: _hasLedger),
    );
    if (saved == true) _reload();
  }

  Future<void> _reverse(Purchase p) async {
    final s = SessionScope.of(context);
    final reason = await askReason(context, title: 'Reverse bill ${p.billNo ?? ''}');
    if (reason == null || !mounted) return;
    if (await runAction(context, () => s.api.reversePurchase(p.id, reason), success: 'Bill reversed')) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: 'Purchases & suppliers', actions: [
          FilledButton.icon(onPressed: _newBill, icon: const Icon(Icons.add), label: const Text('Enter supplier bill')),
        ]),
        const TabBar(tabs: [Tab(text: 'Bills'), Tab(text: 'Suppliers')]),
        Expanded(
          child: TabBarView(children: [
            AsyncStateView<List<Purchase>>(
              future: _purchases,
              onRetry: _reload,
              isEmpty: (l) => l.isEmpty,
              emptyText: 'No bills yet — Enter supplier bill',
              builder: (context, list) => ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final p = list[i];
                  return ListTile(
                    title: Text('${p.supplierName}${p.billNo == null ? '' : ' · ${p.billNo}'}',
                        style: p.reversed ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
                    subtitle: Text('${formatDate(p.billDate)} · paid ${formatPkr(p.paidNow)}'
                        '${p.reversed ? ' · Reversed: ${p.reversalReason ?? ''}' : ''}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(formatPkr(p.total)),
                      if (!p.reversed) TextButton(onPressed: () => _reverse(p), child: const Text('Reverse')),
                    ]),
                  );
                },
              ),
            ),
            _hasLedger
                ? SuppliersTab(future: _suppliers, onChanged: _reload)
                : const LockedFeatureCard(feature: Feature.supplierLedger, title: 'Supplier ledger and dues'),
          ]),
        ),
      ]),
    );
  }
}

class SuppliersTab extends StatelessWidget {
  const SuppliersTab({super.key, required this.future, required this.onChanged});
  final Future<List<Supplier>> future;
  final VoidCallback onChanged;

  Future<void> _add(BuildContext context) async {
    final s = SessionScope.of(context);
    final name = TextEditingController();
    final phone = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add supplier'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 12),
          TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (await runAction(context, () => s.api.saveSupplier(s.current!.stationId, name: name.text, phone: phone.text))) onChanged();
  }

  Future<void> _pay(BuildContext context, Supplier sup) async {
    final s = SessionScope.of(context);
    final amount = TextEditingController();
    final ref = TextEditingController();
    var method = 'cash';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Pay ${sup.name}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Due: ${formatPkr(sup.due)}'),
            const SizedBox(height: 12),
            TextField(controller: amount, decoration: const InputDecoration(labelText: 'Amount (Rs)')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: method,
              decoration: const InputDecoration(labelText: 'Method'),
              items: const ['cash', 'bank', 'jazzcash', 'easypaisa', 'card', 'cheque']
                  .map((m) => DropdownMenuItem(value: m, child: Text(m[0].toUpperCase() + m.substring(1))))
                  .toList(),
              onChanged: (v) => set(() => method = v!),
            ),
            const SizedBox(height: 12),
            TextField(controller: ref, decoration: const InputDecoration(labelText: 'Reference (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Record payment')),
          ],
        ),
      ),
    );
    final m = parsePkr(amount.text);
    if (ok != true || m == null || !context.mounted) return;
    if (await runAction(context, () => s.api.paySupplier(sup.id, m, method, reference: ref.text), success: 'Payment recorded')) onChanged();
  }

  Future<void> _ledger(BuildContext context, Supplier sup) async {
    final s = SessionScope.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${sup.name} — ledger'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: AsyncStateView<List<Map<String, dynamic>>>(
            future: s.api.supplierLedger(sup.id),
            isEmpty: (l) => l.isEmpty,
            builder: (context, rows) => ListView(children: [
              ListTile(title: const Text('Due now'), trailing: Text(formatPkr(sup.due), style: const TextStyle(fontWeight: FontWeight.bold))),
              for (final r in rows)
                ListTile(
                  dense: true,
                  title: Text('${(r['kind'] as String).replaceAll('_', ' ')}${r['method'] == null ? '' : ' · ${r['method']}'}'),
                  subtitle: Text('${formatDate(DateTime.parse(r['created_at'] as String).toLocal())}  ${r['reference'] ?? r['note'] ?? ''}'),
                  trailing: Text(formatPkr(Money.paisa((r['amount_paisa'] as num).toInt()))),
                ),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AsyncStateView<List<Supplier>>(
        future: future,
        onRetry: onChanged,
        builder: (context, list) => ListView(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: OutlinedButton.icon(onPressed: () => _add(context), icon: const Icon(Icons.add), label: const Text('Add supplier')),
            ),
          ),
          for (final sup in list)
            ListTile(
              title: Text(sup.name),
              subtitle: Text('Purchases ${formatPkr(sup.purchases)} · Paid ${formatPkr(sup.payments)}'),
              onTap: () => _ledger(context, sup),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Due ${formatPkr(sup.due)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                TextButton(onPressed: () => _pay(context, sup), child: const Text('Pay')),
              ]),
            ),
        ]),
      );
}

class PurchaseDialog extends StatefulWidget {
  const PurchaseDialog({super.key, required this.items, required this.suppliers, required this.useSupplierList});
  final List<Item> items;
  final List<Supplier> suppliers;
  final bool useSupplierList;

  @override
  State<PurchaseDialog> createState() => _PurchaseDialogState();
}

class _Line {
  _Line(this.itemId);
  String itemId;
  final qty = TextEditingController(text: '1');
  final cost = TextEditingController();
}

class _PurchaseDialogState extends State<PurchaseDialog> {
  final _form = GlobalKey<FormState>();
  final _supplierName = TextEditingController();
  final _billNo = TextEditingController();
  final _paid = TextEditingController(text: '0');
  String? _supplierId;
  final List<_Line> _lines = [];
  bool _busy = false;

  Item _item(String id) => widget.items.firstWhere((i) => i.id == id);

  Money get _total {
    var t = Money.zero;
    for (final l in _lines) {
      final q = num.tryParse(l.qty.text) ?? 0;
      final c = parsePkr(l.cost.text) ?? Money.zero;
      t = t + Money.paisa((c.paisa * q).round());
    }
    return t;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _lines.isEmpty) return;
    final s = SessionScope.of(context);
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      () => s.api.postPurchase(
        s.current!.stationId,
        supplierId: _supplierId,
        supplierName: _supplierName.text,
        billNo: _billNo.text,
        billDate: DateTime.now(),
        lines: [for (final l in _lines) (itemId: l.itemId, qty: num.parse(l.qty.text), unitCost: parsePkr(l.cost.text)!)],
        paidNow: parsePkr(_paid.text) ?? Money.zero,
      ),
      success: 'Bill saved — stock updated',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter supplier bill'),
      content: SizedBox(
        width: 640,
        child: Form(
          key: _form,
          onChanged: () => setState(() {}),
          child: ListView(shrinkWrap: true, children: [
            Row(children: [
              Expanded(
                child: widget.useSupplierList
                    ? DropdownButtonFormField<String>(
                        initialValue: _supplierId,
                        decoration: const InputDecoration(labelText: 'Supplier'),
                        items: widget.suppliers.map((s) => DropdownMenuItem(value: s.id, child: Text(s.name))).toList(),
                        onChanged: (v) => setState(() => _supplierId = v),
                        validator: (v) => v == null ? 'Choose a supplier (add one in the Suppliers tab)' : null,
                      )
                    : TextFormField(
                        controller: _supplierName,
                        decoration: const InputDecoration(labelText: 'Supplier name'),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(controller: _billNo, decoration: const InputDecoration(labelText: 'Bill number'))),
            ]),
            const SizedBox(height: 12),
            for (final l in _lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(
                    flex: 4,
                    child: DropdownButtonFormField<String>(
                      initialValue: l.itemId,
                      isExpanded: true,
                      items: widget.items.map((i) => DropdownMenuItem(value: i.id, child: Text('${i.code} · ${i.name}', overflow: TextOverflow.ellipsis))).toList(),
                      onChanged: (v) => setState(() => l.itemId = v!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: l.qty,
                      decoration: InputDecoration(labelText: 'Qty (${_item(l.itemId).unit.short})'),
                      validator: (v) => qtyValidator(v, _item(l.itemId).unit),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: TextFormField(controller: l.cost, decoration: const InputDecoration(labelText: 'Price each (Rs)'), validator: moneyValidator)),
                  IconButton(onPressed: () => setState(() => _lines.remove(l)), icon: const Icon(Icons.close)),
                ]),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.items.isEmpty ? null : () => setState(() => _lines.add(_Line(widget.items.first.id))),
                icon: const Icon(Icons.add),
                label: Text(widget.items.isEmpty ? 'Add items in Inventory first' : 'Add line'),
              ),
            ),
            const Divider(),
            Row(children: [
              Expanded(child: Text('Total: ${formatPkr(_total)}', style: Theme.of(context).textTheme.titleMedium)),
              SizedBox(
                width: 200,
                child: TextFormField(
                  controller: _paid,
                  decoration: const InputDecoration(labelText: 'Paid now (Rs)'),
                  validator: (v) {
                    final e = moneyValidator(v, required: false);
                    if (e != null) return e;
                    return (parsePkr(v ?? '') ?? Money.zero) > _total ? 'More than total' : null;
                  },
                ),
              ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy || _lines.isEmpty ? null : _save, child: const Text('Save bill')),
      ],
    );
  }
}
