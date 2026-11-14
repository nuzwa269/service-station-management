import 'dart:typed_data';

import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';
import 'invoice_pdf.dart';

/// SCR-007 inside the job card: create the invoice, discount, payments (split),
/// credit release, refunds, reversals, print / share (REQ-036…045).
class InvoiceCard extends StatefulWidget {
  const InvoiceCard({super.key, required this.d, required this.onChanged});
  final JobDetail d;
  final VoidCallback onChanged;

  @override
  State<InvoiceCard> createState() => _InvoiceCardState();
}

class _InvoiceCardState extends State<InvoiceCard> {
  Future<InvoiceDetail?>? _inv;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inv ??= _load();
  }

  @override
  void didUpdateWidget(covariant InvoiceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _inv = _load();
  }

  Future<InvoiceDetail?> _load() async {
    final api = SessionScope.of(context).api;
    final id = await api.invoiceIdForJob(widget.d.job.id);
    return id == null ? null : api.invoice(id);
  }

  Future<void> _act(Future<void> Function() action, {String? success}) async {
    if (await runAction(context, action, success: success)) {
      setState(() => _inv = _load());
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.of(context).api;
    final stage = widget.d.job.stage;
    final canBill = stage != JobStage.intake && stage != JobStage.awaitingApproval;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<InvoiceDetail?>(
          future: _inv,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) return ErrorStateView(message: (snap.error is AppError) ? (snap.error as AppError).message : 'Could not load the invoice');
            final inv = snap.data;
            if (inv == null) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Invoice', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(canBill ? 'No invoice yet.' : 'The invoice is created after the estimate is approved.'),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (canBill && stage != JobStage.delivered)
                    FilledButton.icon(
                      onPressed: () => _act(() => api.createInvoice(widget.d.job.id), success: 'Invoice created'),
                      icon: const Icon(Icons.receipt_long_rounded),
                      label: const Text('Create invoice'),
                    ),
                  if (stage.isOpen)
                    OutlinedButton.icon(
                      onPressed: () async {
                        final r = await showDialog<_PayInput>(context: context, builder: (_) => const PaymentDialog(title: 'Advance payment'));
                        if (r != null) await _act(() => api.recordAdvance(widget.d.job.id, r.amount, r.method, reference: r.reference), success: 'Advance recorded');
                      },
                      icon: const Icon(Icons.savings_rounded),
                      label: const Text('Take advance'),
                    ),
                ]),
              ]);
            }
            return _InvoiceBody(inv: inv, d: widget.d, act: _act);
          },
        ),
      ),
    );
  }
}

class _InvoiceBody extends StatelessWidget {
  const _InvoiceBody({required this.inv, required this.d, required this.act});
  final InvoiceDetail inv;
  final JobDetail d;
  final Future<void> Function(Future<void> Function(), {String? success}) act;

  Color _statusColor(InvoiceStatus s) => switch (s) {
        InvoiceStatus.paid => const Color(0xFF16A34A),
        InvoiceStatus.onCredit => const Color(0xFF8B5CF6),
        InvoiceStatus.partlyPaid => const Color(0xFF0EA5E9),
        InvoiceStatus.discountPending => const Color(0xFFF59E0B),
        InvoiceStatus.unpaid => const Color(0xFFDC2626),
      };

  Future<void> _print(BuildContext context, {required bool share}) async {
    final s = SessionScope.of(context);
    try {
      final station = await s.api.station(s.current!.stationId);
      Uint8List? logo;
      if (station['logo_path'] != null) {
        try {
          logo = await s.api.client.storage.from('station-logos').download(station['logo_path'] as String);
        } catch (_) {
          logo = null; // print without the logo
        }
      }
      final bytes = await buildInvoicePdf(station: station, inv: inv, job: d.job, odometerKm: d.odometerKm, logo: logo);
      final name = 'invoice-${inv.invoiceNo}.pdf';
      share ? await Printing.sharePdf(bytes: bytes, filename: name) : await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final api = s.api;
    final role = s.role!;
    final boss = role == MemberRole.owner || role == MemberRole.manager;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final c = _statusColor(inv.status);

    Widget row(String k, String v, {bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(k, style: TextStyle(color: strong ? null : muted, fontWeight: strong ? FontWeight.w700 : null))),
            Text(v, style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w600, fontSize: strong ? 16 : 14, color: color)),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('Invoice #${inv.invoiceNo}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
          child: Text(inv.status.label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ]),
      const SizedBox(height: 10),
      row('Parts', formatPkr(inv.parts)),
      row('Labour & services', formatPkr(inv.labour)),
      if (inv.discount.paisa > 0)
        row(inv.discountState == 'applied' ? 'Discount' : 'Discount (${inv.discountState})', '−${formatPkr(inv.discount)}',
            color: inv.discountState == 'pending' ? const Color(0xFFF59E0B) : null),
      if (inv.taxParts.paisa + inv.taxServices.paisa > 0) row('Sales tax', formatPkr(inv.taxParts + inv.taxServices)),
      const Divider(),
      row('Total', formatPkr(inv.total), strong: true),
      if (inv.credited.paisa > 0) row('Credit notes', '−${formatPkr(inv.credited)}'),
      row('Paid', formatPkr(inv.paid)),
      row('Due', formatPkr(inv.due), strong: true, color: inv.due.paisa > 0 ? const Color(0xFFDC2626) : const Color(0xFF16A34A)),
      if (inv.customerCredit.paisa > 0) row('Customer credit available', formatPkr(inv.customerCredit)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (inv.due.paisa > 0 && inv.status != InvoiceStatus.discountPending)
          FilledButton.icon(
            onPressed: () async {
              final r = await showDialog<_PayInput>(context: context, builder: (_) => PaymentDialog(title: 'Record payment', due: inv.due));
              if (r != null) await act(() => api.recordPayment(inv.id, r.amount, r.method, reference: r.reference), success: 'Payment recorded');
            },
            icon: const Icon(Icons.payments_rounded),
            label: const Text('Record payment'),
          ),
        if (inv.due.paisa > 0 && inv.customerCredit.paisa > 0)
          OutlinedButton(
            onPressed: () => act(() => api.useCredit(inv.id, inv.customerCredit < inv.due ? inv.customerCredit : inv.due), success: 'Credit used'),
            child: const Text('Use credit'),
          ),
        if (!inv.locked)
          OutlinedButton.icon(
            onPressed: () async {
              final r = await showDialog<(Money, String)>(context: context, builder: (_) => _DiscountDialog(inv: inv));
              if (r != null) {
                await act(() async {
                  final state = await api.setDiscount(inv.id, r.$1, reason: r.$2);
                  if (state == 'pending' && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Discount awaiting approval')));
                  }
                });
              }
            },
            icon: const Icon(Icons.percent_rounded),
            label: const Text('Discount'),
          ),
        if (inv.due.paisa > 0 && inv.status != InvoiceStatus.onCredit && d.job.stage == JobStage.ready)
          OutlinedButton.icon(
            onPressed: () async {
              final reason = await askReason(context, title: 'Request credit for ${formatPkr(inv.due)}', label: 'Why can\'t the customer pay now?');
              if (reason == null) return;
              String? state;
              await act(() async => state = await api.requestCredit(inv.id, reason));
              if (state == 'pending' && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Credit request sent for approval')));
              }
            },
            icon: const Icon(Icons.handshake_rounded),
            label: const Text('Request credit'),
          ),
        if (inv.paid.paisa > 0)
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(context: context, builder: (_) => _RefundDialog(inv: inv));
              if (ok == true) await act(() async {});
            },
            icon: const Icon(Icons.undo_rounded),
            label: const Text('Refund'),
          ),
        if (!inv.locked)
          TextButton(onPressed: () => act(() => api.refreshInvoice(inv.id), success: 'Updated from the job card'), child: const Text('Refresh')),
        IconButton(tooltip: 'Print (A4)', onPressed: () => _print(context, share: false), icon: const Icon(Icons.print_rounded)),
        IconButton(tooltip: 'Download / share PDF', onPressed: () => _print(context, share: true), icon: const Icon(Icons.picture_as_pdf_rounded)),
      ]),
      if (inv.payments.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('Payments', style: TextStyle(fontWeight: FontWeight.w700)),
        for (final p in inv.payments)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${p.method.label} · ${formatPkr(p.amount)}',
                style: TextStyle(decoration: p.reversed ? TextDecoration.lineThrough : null, fontWeight: FontWeight.w600)),
            subtitle: Text([
              formatDate(p.paidOn),
              p.kind.replaceAll('_', ' '),
              if (p.reference != null) 'ref ${p.reference}',
              if (p.reason != null) p.reason,
            ].join(' · ')),
            trailing: boss && p.reversible
                ? TextButton(
                    onPressed: () async {
                      final reason = await askReason(context, title: 'Reverse ${formatPkr(p.amount)}');
                      if (reason != null) await act(() => api.reversePayment(p.id, reason), success: 'Payment reversed');
                    },
                    child: const Text('Reverse'),
                  )
                : null,
          ),
      ],
      for (final cn in inv.creditNotes)
        Text('Credit note #${cn['cn_no']}: ${formatPkr(Money.paisa((cn['amount_paisa'] as num).toInt()))} (${cn['mode']}) — ${cn['reason']}',
            style: TextStyle(fontSize: 12, color: muted)),
    ]);
  }
}

class _PayInput {
  const _PayInput(this.amount, this.method, this.reference);
  final Money amount;
  final PayMethod method;
  final String? reference;
}

/// REQ-038: amount, method, reference for non-cash, and change for cash.
class PaymentDialog extends StatefulWidget {
  const PaymentDialog({super.key, required this.title, this.due});
  final String title;
  final Money? due;

  @override
  State<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<PaymentDialog> {
  final _form = GlobalKey<FormState>();
  late final _amount = TextEditingController(text: widget.due == null ? '' : '${widget.due!.wholeRupees}');
  final _ref = TextEditingController();
  final _received = TextEditingController();
  PayMethod _method = PayMethod.cash;

  @override
  Widget build(BuildContext context) {
    final amount = parsePkr(_amount.text);
    final received = parsePkr(_received.text);
    final change = amount == null || received == null ? null : changeToReturn(due: amount, cashReceived: received);
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _form,
        onChanged: () => setState(() {}),
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.due != null) Text('Due: ${formatPkr(widget.due!)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              decoration: const InputDecoration(labelText: 'Amount (Rs)'),
              validator: (v) {
                final e = moneyValidator(v);
                if (e != null) return e;
                if (parsePkr(v!)!.paisa == 0) return 'Must be above 0';
                if (widget.due != null && parsePkr(v)! > widget.due!) return 'More than the due — split or reduce';
                return null;
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PayMethod>(
              initialValue: _method,
              decoration: const InputDecoration(labelText: 'Method'),
              items: [for (final m in PayMethod.receivable) DropdownMenuItem(value: m, child: Text(m.label))],
              onChanged: (m) => setState(() => _method = m!),
            ),
            const SizedBox(height: 12),
            if (_method.needsReference)
              TextFormField(
                controller: _ref,
                decoration: const InputDecoration(labelText: 'Reference number'),
                validator: (v) => (v ?? '').trim().length < 2 ? 'Required for ${_method.label}' : null,
              )
            else ...[
              TextFormField(controller: _received, decoration: const InputDecoration(labelText: 'Cash received (optional)')),
              if (change != null && change.paisa > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Change to return: ${formatPkr(change)}', style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF16A34A))),
                ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, _PayInput(parsePkr(_amount.text)!, _method, _method.needsReference ? _ref.text.trim() : null));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({required this.inv});
  final InvoiceDetail inv;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final m = parsePkr(_amount.text);
    final pct = m == null || widget.inv.subtotal.paisa == 0 ? null : m.paisa * 100 / widget.inv.subtotal.paisa;
    return AlertDialog(
      title: const Text('Discount'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Subtotal: ${formatPkr(widget.inv.subtotal)}'),
          const SizedBox(height: 12),
          TextField(controller: _amount, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Discount (Rs)')),
          if (pct != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${pct.toStringAsFixed(1)} % of subtotal')),
          const SizedBox(height: 12),
          TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason')),
          const SizedBox(height: 8),
          const Text('Above the owner\'s limit it goes for approval (or needs the owner\'s login on Basic).', style: TextStyle(fontSize: 12)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: m == null ? null : () => Navigator.pop(context, (m, _reason.text.trim())), child: const Text('Apply')),
      ],
    );
  }
}

/// REQ-041: refund as cash or customer credit, optionally returning unused parts to stock.
class _RefundDialog extends StatefulWidget {
  const _RefundDialog({required this.inv});
  final InvoiceDetail inv;

  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  String _mode = 'credit';
  final Map<String, num> _returns = {};

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.of(context).api;
    final parts = widget.inv.lines.where((l) => l.kind == LineKind.part && l.qty > l.returnedQty).toList();
    return AlertDialog(
      title: Text('Refund — invoice #${widget.inv.invoiceNo}'),
      content: SizedBox(
        width: 440,
        child: ListView(shrinkWrap: true, children: [
          TextField(controller: _amount, decoration: InputDecoration(labelText: 'Amount (Rs)', helperText: 'Paid: ${formatPkr(widget.inv.paid)}')),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'credit', label: Text('Keep as credit')), ButtonSegment(value: 'cash', label: Text('Give cash back'))],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          const SizedBox(height: 12),
          TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason')),
          if (parts.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Unused parts coming back to stock'),
            for (final l in parts)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _returns.containsKey(l.id),
                title: Text('${l.description} × ${l.qty - l.returnedQty}'),
                onChanged: (v) => setState(() => v == true ? _returns[l.id] = l.qty - l.returnedQty : _returns.remove(l.id)),
              ),
          ],
          const SizedBox(height: 8),
          const Text('The owner\'s refund applies at once; others go for approval. A numbered credit note is issued.', style: TextStyle(fontSize: 12)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final m = parsePkr(_amount.text);
            if (m == null || m.paisa <= 0) return;
            String? state;
            final ok = await runAction(context, () async {
              state = await api.requestRefund(widget.inv.id, m,
                  mode: _mode, reason: _reason.text.trim(), returns: [for (final e in _returns.entries) (lineId: e.key, qty: e.value)]);
            });
            if (!ok || !context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(state == 'approved' ? 'Credit note issued' : 'Refund sent for approval')));
            Navigator.pop(context, true);
          },
          child: const Text('Refund'),
        ),
      ],
    );
  }
}
