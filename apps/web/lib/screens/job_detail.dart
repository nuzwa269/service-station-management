import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';
import 'invoice_panel.dart';
import 'jobs_screen.dart';

/// SCR-006 — one job card: intake to quality check, approvals, lines, mechanics, history.
class JobDetailView extends StatefulWidget {
  const JobDetailView({super.key, required this.jobId, required this.onChanged, required this.onOpenJob, this.onClose});
  final String jobId;
  final VoidCallback onChanged;
  final void Function(String jobId) onOpenJob;
  final VoidCallback? onClose;

  @override
  State<JobDetailView> createState() => _JobDetailViewState();
}

class _JobDetailViewState extends State<JobDetailView> {
  late Future<JobDetail> _job;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() => setState(() => _job = SessionScope.of(context).api.job(widget.jobId));

  Future<void> _act(Future<void> Function() action, {String? success}) async {
    if (await runAction(context, action, success: success)) {
      _reload();
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) => AsyncStateView<JobDetail>(
        future: _job,
        onRetry: _reload,
        builder: (context, d) => ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          _Header(d: d, onClose: widget.onClose),
          const SizedBox(height: 12),
          _Actions(d: d, act: _act, onOpenJob: widget.onOpenJob),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            final two = c.maxWidth >= 760;
            final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _LinesCard(d: d, act: _act),
              const SizedBox(height: 12),
              _ChecklistCard(d: d, act: _act),
            ]);
            final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (SessionScope.of(context).role != MemberRole.mechanic) ...[
                InvoiceCard(d: d, onChanged: () {
                  _reload();
                  widget.onChanged();
                }),
                const SizedBox(height: 12),
              ],
              _IntakeCard(d: d),
              const SizedBox(height: 12),
              _MechanicsCard(d: d, act: _act),
              const SizedBox(height: 12),
              _HistoryCard(d: d),
            ]);
            return two
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 3, child: left),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: right),
                  ])
                : Column(children: [left, const SizedBox(height: 12), right]);
          }),
        ]),
      );
}

class _Box extends StatelessWidget {
  const _Box({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))), ?trailing]),
            const SizedBox(height: 10),
            child,
          ]),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.d, this.onClose});
  final JobDetail d;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final j = d.job;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          if (onClose != null) IconButton(onPressed: onClose, icon: const Icon(Icons.arrow_back_rounded)),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: stageColors[j.stage]!.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
            alignment: Alignment.center,
            child: Icon(Icons.directions_car_rounded, color: stageColors[j.stage]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Job #${j.jobNo}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                if (j.kind != 'normal') ...[
                  const SizedBox(width: 8),
                  Chip(label: Text(j.kind == 'rework' ? 'Rework' : 'Warranty'), visualDensity: VisualDensity.compact),
                ],
              ]),
              Text('${j.plate} · ${j.vehicleName ?? ''} · ${j.customerName} · ${formatPkMobile(d.customerMobile)}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
          StageChip(j.stage),
        ]),
      ),
    );
  }
}

/// Stage-aware action bar: only the next sensible steps are shown.
class _Actions extends StatelessWidget {
  const _Actions({required this.d, required this.act, required this.onOpenJob});
  final JobDetail d;
  final Future<void> Function(Future<void> Function(), {String? success}) act;
  final void Function(String) onOpenJob;

  Future<void> _approval(BuildContext context, {required bool extra}) async {
    final api = SessionScope.of(context).api;
    final name = TextEditingController(text: d.job.customerName);
    var via = 'phone';
    final approve = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(extra ? 'Customer decision on extra work' : 'Customer decision on estimate'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Approved / rejected by')),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'phone', label: Text('By phone')), ButtonSegment(value: 'in_person', label: Text('In person'))],
              selected: {via},
              onSelectionChanged: (v) => set(() => via = v.first),
            ),
            if (!extra) ...[
              const SizedBox(height: 12),
              const Text('Rejecting cancels the job and adds the inspection fee.', style: TextStyle(fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')),
            OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Rejected')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approved')),
          ],
        ),
      ),
    );
    if (approve == null) return;
    await act(() => api.recordApproval(d.job.id, approve: approve, via: via, byName: name.text, extra: extra),
        success: approve ? 'Approval recorded' : 'Rejection recorded');
  }

  Future<void> _qc(BuildContext context, bool pass) async {
    final api = SessionScope.of(context).api;
    String? note;
    if (!pass) {
      note = await askReason(context, title: 'Quality check failed', label: 'Note for the mechanic');
      if (note == null) return;
    }
    await act(() => api.qualityCheck(d.job.id, pass: pass, note: note), success: pass ? 'Ready for delivery' : 'Sent back to the mechanic');
  }

  Future<void> _cancel(BuildContext context) async {
    final api = SessionScope.of(context).api;
    final reason = await askReason(context, title: 'Cancel job #${d.job.jobNo}');
    if (reason == null) return;
    await act(() => api.cancelJob(d.job.id, reason), success: 'Job cancelled');
  }

  Future<void> _rework(BuildContext context) async {
    final api = SessionScope.of(context).api;
    final complaints = TextEditingController();
    final odo = TextEditingController(text: '${d.odometerKm}');
    var partsFree = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Rework (comeback)'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: complaints, decoration: const InputDecoration(labelText: 'What came back?')),
            const SizedBox(height: 12),
            TextField(controller: odo, decoration: const InputDecoration(labelText: 'Odometer (km)')),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: partsFree, onChanged: (v) => set(() => partsFree = v), title: const Text('New parts free of charge')),
            const Text('Labour on a rework job is always free.', style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create rework job')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    String? id;
    if (await runAction(context, () async {
      id = await api.createRework(d.job.id, partsFree: partsFree, odometer: int.tryParse(odo.text) ?? d.odometerKm, fuel: d.fuel, complaints: complaints.text);
    })) {
      onOpenJob(id!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final role = s.role!;
    final boss = role == MemberRole.owner || role == MemberRole.manager;
    final api = s.api;
    final stage = d.job.stage;
    final buttons = <Widget>[
      if (stage == JobStage.intake)
        FilledButton.icon(
          onPressed: () => act(() => api.sendEstimate(d.job.id), success: 'Estimate sent'),
          icon: const Icon(Icons.send_rounded),
          label: Text('Send estimate (${formatPkr(d.total)})'),
        ),
      if (stage == JobStage.intake || stage == JobStage.awaitingApproval)
        FilledButton.tonalIcon(onPressed: () => _approval(context, extra: false), icon: const Icon(Icons.how_to_reg_rounded), label: const Text('Record customer decision')),
      if (d.hasExtraPending)
        FilledButton.tonalIcon(onPressed: () => _approval(context, extra: true), icon: const Icon(Icons.playlist_add_check_rounded), label: const Text('Extra work decision')),
      if (stage == JobStage.approved)
        FilledButton.icon(onPressed: () => act(() => api.setStage(d.job.id, JobStage.inProgress)), icon: const Icon(Icons.play_arrow_rounded), label: const Text('Start work')),
      if (stage == JobStage.inProgress)
        FilledButton.icon(
            onPressed: () => act(() => api.setStage(d.job.id, JobStage.qualityCheck)), icon: const Icon(Icons.rule_rounded), label: const Text('Request quality check')),
      if (stage == JobStage.qualityCheck && boss) ...[
        FilledButton.icon(onPressed: () => _qc(context, true), icon: const Icon(Icons.verified_rounded), label: const Text('QC pass')),
        OutlinedButton.icon(onPressed: () => _qc(context, false), icon: const Icon(Icons.replay_rounded), label: const Text('QC fail')),
      ],
      if (stage == JobStage.ready)
        FilledButton.icon(
          onPressed: () async {
            if (await confirmAction(context, 'Deliver vehicle', 'Hand over ${d.job.plate} to the customer?')) {
              await act(() => api.setStage(d.job.id, JobStage.delivered), success: 'Delivered');
            }
          },
          icon: const Icon(Icons.key_rounded),
          label: const Text('Deliver'),
        ),
      if (stage == JobStage.delivered && d.job.kind == 'normal')
        OutlinedButton.icon(onPressed: () => _rework(context), icon: const Icon(Icons.build_circle_rounded), label: const Text('Rework')),
      if (stage.isOpen && (boss || stage == JobStage.intake || stage == JobStage.awaitingApproval))
        TextButton.icon(onPressed: () => _cancel(context), icon: const Icon(Icons.cancel_outlined), label: const Text('Cancel job')),
    ];
    final note = switch (stage) {
      JobStage.awaitingApproval => 'Waiting for the customer to approve the estimate.',
      JobStage.approved when d.approvedByName != null => 'Approved by ${d.approvedByName} (${(d.approvedVia ?? '').replaceAll('_', ' ')})'
          '${d.approvedAt == null ? '' : ', ${formatDate(d.approvedAt!.toLocal())} ${formatTime(d.approvedAt!.toLocal())}'}.',
      JobStage.inProgress when d.qcNote != null => 'Quality check failed: ${d.qcNote}',
      JobStage.cancelled => 'Cancelled: ${d.cancelReason ?? ''}. The fee invoice is created with billing (Phase 4).',
      JobStage.ready => 'Payment and credit checks at delivery arrive with billing (Phase 4).',
      _ => null,
    };
    if (buttons.isEmpty && note == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (note != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(note)),
          Wrap(spacing: 8, runSpacing: 8, children: buttons),
        ]),
      ),
    );
  }
}

class _LinesCard extends StatelessWidget {
  const _LinesCard({required this.d, required this.act});
  final JobDetail d;
  final Future<void> Function(Future<void> Function(), {String? success}) act;

  Future<void> _add(BuildContext context) async {
    final added = await showDialog<bool>(context: context, builder: (_) => AddLineDialog(jobId: d.job.id));
    if (added == true) await act(() async {});
  }

  Future<void> _warranty(BuildContext context, JobLine l) async {
    final api = SessionScope.of(context).api;
    final w = await api.warrantyStatus(l.id);
    if (!context.mounted) return;
    if (w['valid'] != true) {
      showError(context, AppError(AppErrorCode.warrantyExpired,
          w['expires_on'] == null ? (w['reason'] as String? ?? 'No warranty') : 'Warranty expired on ${formatDate(DateTime.parse(w['expires_on'] as String))}'));
      return;
    }
    final ok = await confirmAction(context, 'Warranty claim',
        '${l.description}: ${w['days_left']} days of warranty left (until ${formatDate(DateTime.parse(w['expires_on'] as String))}). Labour and replacement are free. Open a claim?');
    if (!ok || !context.mounted) return;
    await act(() => api.createWarrantyClaim(l.id, odometer: d.odometerKm, fuel: d.fuel), success: 'Warranty job created — see open jobs');
  }

  @override
  Widget build(BuildContext context) {
    final open = d.job.stage.isOpen && d.job.stage != JobStage.ready;
    final scheme = Theme.of(context).colorScheme;
    final shown = d.lines.where((l) => l.status != LineStatus.removed).toList();
    return _Box(
      title: 'Estimate & work',
      trailing: open ? TextButton.icon(onPressed: () => _add(context), icon: const Icon(Icons.add_rounded), label: const Text('Add line')) : null,
      child: Column(children: [
        if (shown.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No lines yet — add parts and labour')),
        for (final l in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(
                switch (l.kind) {
                  LineKind.part => Icons.settings_rounded,
                  LineKind.labour => Icons.handyman_rounded,
                  LineKind.fee => Icons.receipt_rounded,
                  LineKind.customerPart => Icons.person_pin_rounded,
                },
                size: 18,
                color: const Color(0xFF64748B),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.description,
                      style: TextStyle(fontWeight: FontWeight.w600, decoration: l.status == LineStatus.rejected ? TextDecoration.lineThrough : null)),
                  Text('${l.kind.label} · qty ${l.qty} × ${formatPkr(l.unitPrice)}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (l.status != LineStatus.approved)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(l.status.label,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: l.status == LineStatus.extraPending ? const Color(0xFFF59E0B) : scheme.onSurfaceVariant)),
                ),
              SizedBox(width: 90, child: Text(formatPkr(l.total), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (open && l.status.counts && l.kind != LineKind.fee)
                IconButton(
                  tooltip: 'Remove',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => act(() => SessionScope.of(context).api.removeLine(l.id)),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              if (d.job.stage == JobStage.delivered && l.warrantyDays > 0)
                TextButton(onPressed: () => _warranty(context, l), child: const Text('Warranty')),
            ]),
          ),
        const Divider(),
        Row(children: [
          const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))),
          Text(formatPkr(d.total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ]),
      ]),
    );
  }
}

class AddLineDialog extends StatefulWidget {
  const AddLineDialog({super.key, required this.jobId, this.checkId, this.presetDescription});
  final String jobId;
  final String? checkId;
  final String? presetDescription;

  @override
  State<AddLineDialog> createState() => _AddLineDialogState();
}

class _AddLineDialogState extends State<AddLineDialog> {
  LineKind _kind = LineKind.part;
  Future<List<Item>>? _items;
  Future<List<Service>>? _services;
  Item? _item;
  Service? _service;
  late final _desc = TextEditingController(text: widget.presetDescription);
  final _qty = TextEditingController(text: '1');
  final _price = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = SessionScope.of(context);
    _items ??= s.api.items(s.current!.stationId);
    _services ??= s.api.services(s.current!.stationId);
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    return AlertDialog(
      title: Text(widget.checkId == null ? 'Add line' : 'Add to estimate'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<LineKind>(
            segments: [
              const ButtonSegment(value: LineKind.part, label: Text('Part')),
              const ButtonSegment(value: LineKind.labour, label: Text('Labour')),
              if (widget.checkId == null) const ButtonSegment(value: LineKind.customerPart, label: Text('Customer part')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: 12),
          if (_kind == LineKind.part)
            FutureBuilder<List<Item>>(
              future: _items,
              builder: (context, snap) {
                final items = (snap.data ?? const <Item>[]).where((i) => i.active).toList();
                return Autocomplete<Item>(
                  displayStringForOption: (i) => '${i.code} · ${i.name}',
                  optionsBuilder: (v) {
                    final q = v.text.toLowerCase();
                    return items.where((i) => q.isEmpty || i.name.toLowerCase().contains(q) || i.code.toLowerCase().contains(q) || i.barcode == v.text).take(20);
                  },
                  onSelected: (i) => setState(() {
                    _item = i;
                    _price.text = (i.sellingPrice.paisa / 100).toStringAsFixed(0);
                  }),
                  fieldViewBuilder: (context, c, f, _) =>
                      TextField(controller: c, focusNode: f, decoration: const InputDecoration(labelText: 'Search part by name, code or barcode')),
                );
              },
            )
          else ...[
            if (_kind == LineKind.labour && widget.checkId == null)
              FutureBuilder<List<Service>>(
                future: _services,
                builder: (context, snap) {
                  final list = (snap.data ?? const <Service>[]).where((x) => x.active).toList();
                  if (list.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DropdownButtonFormField<Service?>(
                      initialValue: _service,
                      decoration: const InputDecoration(labelText: 'From the service list (optional)'),
                      items: [
                        const DropdownMenuItem<Service?>(value: null, child: Text('— Free text —')),
                        for (final x in list) DropdownMenuItem<Service?>(value: x, child: Text('${x.name} · ${formatPkr(x.rate)}')),
                      ],
                      onChanged: (x) => setState(() {
                        _service = x;
                        if (x != null) {
                          _desc.text = x.name;
                          _price.text = '${x.rate.wholeRupees}';
                        }
                      }),
                    ),
                  );
                },
              ),
            TextField(controller: _desc, decoration: InputDecoration(labelText: _kind == LineKind.labour ? 'Work description' : 'Part brought by customer')),
          ],
          if (_item != null && _kind == LineKind.part)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('In stock: ${formatQty(_item!.onHand, _item!.unit)}', style: const TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _qty, decoration: InputDecoration(labelText: 'Qty${_item == null ? '' : ' (${_item!.unit.short})'}'))),
            const SizedBox(width: 8),
            if (_kind != LineKind.customerPart)
              Expanded(child: TextField(controller: _price, decoration: const InputDecoration(labelText: 'Price each (Rs)'))),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final qty = num.tryParse(_qty.text.trim());
            if (qty == null || qty <= 0) return;
            if (_kind == LineKind.part && _item == null) return;
            final price = parsePkr(_price.text);
            final ok = await runAction(context, () async {
              if (widget.checkId != null) {
                await s.api.checkToEstimate(widget.checkId!, itemId: _kind == LineKind.part ? _item!.id : null, description: _desc.text, price: price);
              } else if (_kind == LineKind.labour && _service != null) {
                await s.api.addService(widget.jobId, _service!.id, qty: qty, price: price);
              } else {
                await s.api.addLine(widget.jobId, _kind, itemId: _item?.id, description: _desc.text, qty: qty, price: price);
              }
            });
            if (ok && context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _ChecklistCard extends StatelessWidget {
  const _ChecklistCard({required this.d, required this.act});
  final JobDetail d;
  final Future<void> Function(Future<void> Function(), {String? success}) act;

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.of(context).api;
    final open = d.job.stage.isOpen;
    final done = d.checklist.where((c) => c.status != CheckStatus.notChecked).length;
    return _Box(
      title: 'Inspection checklist',
      trailing: d.checklist.isEmpty ? null : Text('$done / ${d.checklist.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      child: d.checklist.isEmpty
          ? const Text('No checklist — the owner can set one in Settings.')
          : Column(children: [
              for (final c in d.checklist)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (c.note != null) Text(c.note!, style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
                    SegmentedButton<CheckStatus>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: const [
                        ButtonSegment(value: CheckStatus.ok, label: Text('OK')),
                        ButtonSegment(value: CheckStatus.attention, label: Text('Attention')),
                      ],
                      emptySelectionAllowed: true,
                      selected: c.status == CheckStatus.notChecked ? {} : {c.status},
                      onSelectionChanged: open
                          ? (v) => act(() => api.setCheck(c.id, v.isEmpty ? CheckStatus.notChecked : v.first, note: c.note))
                          : null,
                    ),
                    if (c.status == CheckStatus.attention && open)
                      IconButton(
                        tooltip: 'Add to estimate',
                        icon: const Icon(Icons.add_shopping_cart_rounded, size: 20),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                              context: context, builder: (_) => AddLineDialog(jobId: d.job.id, checkId: c.id, presetDescription: c.name));
                          if (ok == true) await act(() async {});
                        },
                      ),
                  ]),
                ),
            ]),
    );
  }
}

class _IntakeCard extends StatelessWidget {
  const _IntakeCard({required this.d});
  final JobDetail d;

  @override
  Widget build(BuildContext context) {
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 120, child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        );
    return _Box(
      title: 'Intake',
      child: Column(children: [
        row('Odometer', '${d.odometerKm} km'),
        row('Fuel', d.fuel.label),
        row('Opened', '${formatDate(d.job.createdAt.toLocal())} ${formatTime(d.job.createdAt.toLocal())}'),
        if (d.expectedDelivery != null) row('Expected', '${formatDate(d.expectedDelivery!.toLocal())} ${formatTime(d.expectedDelivery!.toLocal())}'),
        if ((d.job.complaints ?? '').isNotEmpty) row('Complaints', d.job.complaints!),
        if (d.partsFree) row('Parts', 'Free of charge'),
      ]),
    );
  }
}

class _MechanicsCard extends StatefulWidget {
  const _MechanicsCard({required this.d, required this.act});
  final JobDetail d;
  final Future<void> Function(Future<void> Function(), {String? success}) act;

  @override
  State<_MechanicsCard> createState() => _MechanicsCardState();
}

class _MechanicsCardState extends State<_MechanicsCard> {
  Future<List<Member>>? _members;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = SessionScope.of(context);
    _members ??= s.role == MemberRole.cashier ? Future.value(const []) : s.api.members(s.current!.stationId);
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.of(context).api;
    final d = widget.d;
    return _Box(
      title: 'Mechanics',
      child: FutureBuilder<List<Member>>(
        future: _members,
        builder: (context, snap) {
          final mechanics = (snap.data ?? const <Member>[]).where((m) => m.active && m.role == MemberRole.mechanic).toList();
          if (mechanics.isEmpty) {
            return Text(d.job.mechanics.isEmpty ? 'No mechanic assigned' : d.job.mechanics.join(', '));
          }
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in mechanics)
              FilterChip(
                avatar: const Icon(Icons.engineering_rounded, size: 16),
                label: Text(m.name),
                selected: d.mechanicIds.contains(m.userId),
                onSelected: d.job.stage.isOpen
                    ? (v) {
                        final ids = {...d.mechanicIds};
                        v ? ids.add(m.userId) : ids.remove(m.userId);
                        widget.act(() => api.assignMechanics(d.job.id, ids.toList()));
                      }
                    : null,
              ),
          ]);
        },
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.d});
  final JobDetail d;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return _Box(
      title: 'History',
      child: Column(children: [
        for (final h in d.history.take(12))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(h['conflict'] == true ? Icons.sync_problem_rounded : (h['source'] == 'sync' ? Icons.phone_android_rounded : Icons.circle),
                  size: h['conflict'] == true || h['source'] == 'sync' ? 16 : 8, color: h['conflict'] == true ? Colors.orange : muted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_describe(h), style: const TextStyle(fontSize: 13)),
                  Text(_when(h['created_at'] as String), style: TextStyle(fontSize: 11.5, color: muted)),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }

  static String _when(String iso) {
    final t = DateTime.parse(iso).toLocal();
    return '${formatDate(t)} ${formatTime(t)}';
  }

  static String _describe(Map<String, dynamic> h) {
    final f = h['field'] as String;
    final nv = (h['new_value'] as String?)?.replaceAll('_', ' ') ?? '';
    final note = h['note'] as String?;
    final base = switch (f) {
      'stage' => 'Stage → $nv',
      'qc' => 'Quality check → $nv',
      'assigned' => 'Assigned: $nv',
      'approval' => nv,
      _ when f.startsWith('line:') => nv == 'removed' ? 'Line removed: ${h['old_value']}' : 'Line added: $nv',
      _ when f.startsWith('checklist:') => 'Checklist → $nv',
      _ => '$f → $nv',
    };
    return [base, if (note != null && note.isNotEmpty) note, if (h['conflict'] == true) '(overwritten by a later change)'].join(' — ');
  }
}
