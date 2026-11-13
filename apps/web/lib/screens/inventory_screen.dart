import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';

/// SCR-009 — items, stock, prices, kits; low-stock list (REQ-028, REQ-033).
class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  late Future<List<Item>> _items;
  String _query = '';
  bool _lowOnly = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    setState(() => _items = s.api.items(s.current!.stationId, withCost: s.role == MemberRole.owner));
  }

  Future<void> _edit(List<Item> all, [Item? item]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => ItemDialog(item: item, allItems: all));
    if (saved == true) _reload();
  }

  Future<void> _adjust(Item item) async {
    final done = await showDialog<bool>(context: context, builder: (_) => AdjustStockDialog(item: item));
    if (done == true) _reload();
  }

  Future<void> _setCost(Item item) async {
    final s = SessionScope.of(context);
    final c = TextEditingController(text: item.avgCost == null ? '' : (item.avgCost!.paisa / 100).toStringAsFixed(2));
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cost of ${item.name}'),
        content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Average cost (Rs)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    final m = value == null ? null : parsePkr(value);
    if (m == null || !mounted) return;
    if (await runAction(context, () => s.api.setItemCost(item.id, m))) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final role = s.role!;
    final canEdit = role == MemberRole.owner || role == MemberRole.manager;
    return AsyncStateView<List<Item>>(
      future: _items,
      onRetry: _reload,
      builder: (context, all) {
        final q = _query.toLowerCase();
        final low = all.where((i) => i.active && i.isLow).toList();
        final shown = all
            .where((i) => !_lowOnly || i.isLow)
            .where((i) => q.isEmpty || i.name.toLowerCase().contains(q) || i.code.toLowerCase().contains(q) || (i.barcode ?? '') == _query)
            .toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(title: 'Inventory', actions: [
            if (canEdit) FilledButton.icon(onPressed: () => _edit(all), icon: const Icon(Icons.add), label: const Text('Add item')),
            SizedBox(
              width: 260,
              child: TextField(
                decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Name, code or barcode'),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            FilterChip(
              label: Text('Low stock (${low.length})'),
              selected: _lowOnly,
              onSelected: (v) => setState(() => _lowOnly = v),
            ),
          ]),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(all.isEmpty ? 'No items yet — Add item or import from Excel (Settings)' : 'No matching items'))
                : SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: [
                          const DataColumn(label: Text('Code')),
                          const DataColumn(label: Text('Name')),
                          const DataColumn(label: Text('Stock'), numeric: true),
                          const DataColumn(label: Text('Min'), numeric: true),
                          const DataColumn(label: Text('Selling price'), numeric: true),
                          if (role == MemberRole.owner) const DataColumn(label: Text('Avg cost'), numeric: true),
                          const DataColumn(label: Text('')),
                        ],
                        rows: [
                          for (final i in shown)
                            DataRow(cells: [
                              DataCell(Text(i.code)),
                              DataCell(Text(i.active ? i.name : '${i.name} (inactive)')),
                              DataCell(Text(
                                i.unit == ItemUnit.kit ? 'kit' : formatQty(i.onHand, i.unit),
                                style: TextStyle(
                                  color: i.isLow ? Theme.of(context).colorScheme.error : null,
                                  fontWeight: i.isLow ? FontWeight.bold : null,
                                ),
                              )),
                              DataCell(Text(i.minStock == 0 ? '—' : formatQty(i.minStock, i.unit))),
                              DataCell(Text(formatPkr(i.sellingPrice))),
                              if (role == MemberRole.owner)
                                DataCell(Text(i.avgCost == null ? '—' : formatPkr(i.avgCost!)), onTap: () => _setCost(i)),
                              DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                                if (canEdit) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(all, i)),
                                if (i.unit != ItemUnit.kit)
                                  IconButton(tooltip: 'Adjust stock', icon: const Icon(Icons.exposure_outlined), onPressed: () => _adjust(i)),
                              ])),
                            ]),
                        ],
                      ),
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}

class ItemDialog extends StatefulWidget {
  const ItemDialog({super.key, this.item, required this.allItems});
  final Item? item;
  final List<Item> allItems;

  @override
  State<ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<ItemDialog> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.item?.code);
  late final _name = TextEditingController(text: widget.item?.name);
  late final _barcode = TextEditingController(text: widget.item?.barcode);
  late final _category = TextEditingController(text: widget.item?.category);
  late final _price = TextEditingController(text: widget.item == null ? '' : (widget.item!.sellingPrice.paisa / 100).toStringAsFixed(0));
  late final _min = TextEditingController(text: widget.item == null ? '0' : widget.item!.minStock.toString());
  late final _warranty = TextEditingController(text: (widget.item?.warrantyDays ?? 0).toString());
  late ItemUnit _unit = widget.item?.unit ?? ItemUnit.piece;
  late bool _bulk = widget.item?.isBulk ?? false;
  late bool _active = widget.item?.active ?? true;
  final List<({String itemId, TextEditingController qty})> _components = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.item?.unit == ItemUnit.kit) _loadComponents();
  }

  Future<void> _loadComponents() async {
    final api = SessionScope.of(context).api;
    final comps = await api.kitComponents(widget.item!.id);
    if (!mounted) return;
    setState(() {
      for (final c in comps) {
        _components.add((itemId: c.itemId, qty: TextEditingController(text: c.qty.toString())));
      }
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final price = parsePkr(_price.text) ?? Money.zero;
    final avg = widget.item?.avgCost;
    if (avg != null && price < avg) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Price below cost'),
          content: Text('Selling price ${formatPkr(price)} is below the average cost ${formatPkr(avg)}. Save anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    final s = SessionScope.of(context);
    setState(() => _busy = true);
    final ok = await runAction(context, () => s.api.saveItem(
          s.current!.stationId,
          {
            'id': widget.item?.id,
            'code': _code.text.trim(),
            'name': _name.text.trim(),
            'barcode': _barcode.text.trim(),
            'category': _category.text.trim(),
            'unit': _unit.name,
            'is_bulk': _bulk,
            'selling_price_paisa': price.paisa,
            'min_stock': num.tryParse(_min.text) ?? 0,
            'warranty_days': int.tryParse(_warranty.text) ?? 0,
            'active': _active,
          },
          components: _unit == ItemUnit.kit
              ? [for (final c in _components) (itemId: c.itemId, qty: num.tryParse(c.qty.text) ?? 0)]
              : null,
        ));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = widget.allItems.where((i) => i.unit != ItemUnit.kit && i.id != widget.item?.id).toList();
    return AlertDialog(
      title: Text(widget.item == null ? 'Add item' : 'Edit item'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: ListView(shrinkWrap: true, children: [
            Row(children: [
              Expanded(child: TextFormField(controller: _code, decoration: const InputDecoration(labelText: 'Code'), validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null)),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(controller: _barcode, decoration: const InputDecoration(labelText: 'Barcode / QR (optional)'))),
            ]),
            const SizedBox(height: 12),
            TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name'), validator: (v) => (v ?? '').trim().length < 2 ? 'Name missing' : null),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextFormField(controller: _category, decoration: const InputDecoration(labelText: 'Category'))),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<ItemUnit>(
                  initialValue: _unit,
                  decoration: const InputDecoration(labelText: 'Unit'),
                  items: ItemUnit.values.map((u) => DropdownMenuItem(value: u, child: Text(u.label))).toList(),
                  onChanged: (u) => setState(() {
                    _unit = u!;
                    if (_unit != ItemUnit.litre) _bulk = false;
                  }),
                ),
              ),
            ]),
            if (_unit == ItemUnit.litre)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _bulk,
                onChanged: (v) => setState(() => _bulk = v!),
                title: const Text('Bulk container (drum) — sold in part litres'),
              ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextFormField(controller: _price, decoration: const InputDecoration(labelText: 'Selling price (Rs)'), validator: moneyValidator)),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: _min,
                  decoration: InputDecoration(labelText: 'Minimum stock (${_unit.short})'),
                  validator: (v) => qtyValidator(v, _unit, allowZero: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(controller: _warranty, decoration: const InputDecoration(labelText: 'Warranty days'))),
            ]),
            if (widget.item != null)
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: const Text('Active')),
            if (_unit == ItemUnit.kit) ...[
              const Divider(),
              const Text('Kit components'),
              for (var i = 0; i < _components.length; i++)
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      initialValue: candidates.any((c) => c.id == _components[i].itemId) ? _components[i].itemId : null,
                      items: candidates.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))).toList(),
                      onChanged: (v) => setState(() => _components[i] = (itemId: v!, qty: _components[i].qty)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: TextFormField(controller: _components[i].qty, decoration: const InputDecoration(labelText: 'Qty'))),
                  IconButton(onPressed: () => setState(() => _components.removeAt(i)), icon: const Icon(Icons.close)),
                ]),
              TextButton.icon(
                onPressed: candidates.isEmpty
                    ? null
                    : () => setState(() => _components.add((itemId: candidates.first.id, qty: TextEditingController(text: '1')))),
                icon: const Icon(Icons.add),
                label: const Text('Add component'),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

/// SCR-011 — REQ-032. Owner's adjustment applies at once; others go for approval.
class AdjustStockDialog extends StatefulWidget {
  const AdjustStockDialog({super.key, required this.item});
  final Item item;

  @override
  State<AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends State<AdjustStockDialog> {
  final _form = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _note = TextEditingController();
  AdjustmentReason _reason = AdjustmentReason.countDifference;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final owner = s.role == MemberRole.owner;
    return AlertDialog(
      title: Text('Adjust stock — ${widget.item.name}'),
      content: Form(
        key: _form,
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Current stock: ${formatQty(widget.item.onHand, widget.item.unit)}'),
            const SizedBox(height: 12),
            TextFormField(
              controller: _qty,
              decoration: InputDecoration(labelText: 'Change (+ or −) in ${widget.item.unit.short}', hintText: '-2'),
              validator: (v) => qtyValidator(v, widget.item.unit, allowNegative: true),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AdjustmentReason>(
              initialValue: _reason,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: AdjustmentReason.values.map((r) => DropdownMenuItem(value: r, child: Text(r.label))).toList(),
              onChanged: (r) => setState(() => _reason = r!),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note'),
              validator: (v) => _reason == AdjustmentReason.other && (v ?? '').trim().length < 3 ? 'Add a note' : null,
            ),
            const SizedBox(height: 8),
            Text(owner ? 'Applies at once and is logged.' : 'Sent for approval. Stock changes only after approval.'),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  if (!_form.currentState!.validate()) return;
                  setState(() => _busy = true);
                  final ok = await runAction(
                    context,
                    () => s.api.requestAdjustment(s.current!.stationId, widget.item.id, num.parse(_qty.text.trim()), _reason, _note.text.trim()),
                    success: owner ? 'Stock adjusted' : 'Sent for approval',
                  );
                  if (!context.mounted) return;
                  setState(() => _busy = false);
                  if (ok) Navigator.pop(context, true);
                },
          child: Text(owner ? 'Adjust' : 'Request approval'),
        ),
      ],
    );
  }
}
