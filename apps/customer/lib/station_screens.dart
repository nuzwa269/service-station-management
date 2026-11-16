import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

Money _m(Object? v) => Money.paisa((v as num? ?? 0).toInt());
DateTime _t(Object? v) => DateTime.parse(v as String);

/// One linked station: bookings, jobs, invoices and vehicles (SCR-042…044).
class StationHome extends StatefulWidget {
  const StationHome({super.key, required this.api, required this.station});
  final StationApi api;
  final LinkedStation station;

  @override
  State<StationHome> createState() => _StationHomeState();
}

class _StationHomeState extends State<StationHome> {
  late Future<Map<String, dynamic>> _data;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() { _data = widget.api.myStationData(widget.station.stationId); });

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.station.name),
            // All four tabs share the width (no tab pushed off the screen); tight padding for big text.
            bottom: const TabBar(labelPadding: EdgeInsets.symmetric(horizontal: 4), tabs: [
              Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Bookings'))),
              Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Jobs'))),
              Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Invoices'))),
              Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Vehicles'))),
            ]),
          ),
          body: AsyncStateView<Map<String, dynamic>>(
            future: _data,
            onRetry: _reload,
            builder: (context, d) => TabBarView(children: [
              _BookingsTab(api: widget.api, station: widget.station, data: d, onChanged: _reload),
              _JobsTab(api: widget.api, data: d, onChanged: _reload),
              _InvoicesTab(api: widget.api, data: d),
              _VehiclesTab(api: widget.api, station: widget.station, data: d, onChanged: _reload),
            ]),
          ),
        ),
      );
}

List<Map<String, dynamic>> _list(Map<String, dynamic> d, String key) => (d[key] as List).cast<Map<String, dynamic>>();

Future<void> _run(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
  } catch (e) {
    if (context.mounted) showError(context, e);
    rethrow;
  }
}

// ---- Bookings (REQ-015, REQ-016) -------------------------------------------------------------
class _BookingsTab extends StatelessWidget {
  const _BookingsTab({required this.api, required this.station, required this.data, required this.onChanged});
  final StationApi api;
  final LinkedStation station;
  final Map<String, dynamic> data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final all = _list(data, 'bookings');
    final now = DateTime.now();
    final upcoming = all.where((b) => b['status'] == 'booked' && _t(b['slot_start']).isAfter(now)).toList().reversed.toList();
    final past = all.where((b) => !upcoming.contains(b)).toList();
    final blocked = station.blocked;
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (blocked)
        const Card(child: ListTile(leading: Icon(Icons.block), title: Text('Please call the station'), subtitle: Text('Online booking is blocked after missed bookings.')))
      else if (station.readOnly)
        const Card(child: ListTile(leading: Icon(Icons.info_outline), title: Text('Online booking is not available at this station right now')))
      else
        FilledButton.icon(
          onPressed: () async {
            final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => BookSlotScreen(api: api, station: station, data: data)));
            if (ok == true) onChanged();
          },
          icon: const Icon(Icons.event_available),
          label: const Text('Book a slot'),
        ),
      const SizedBox(height: 16),
      Text('Upcoming', style: Theme.of(context).textTheme.titleMedium),
      if (upcoming.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No upcoming bookings')),
      for (final b in upcoming) _BookingCard(api: api, station: station, data: data, b: b, onChanged: onChanged),
      if (past.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Earlier', style: Theme.of(context).textTheme.titleMedium),
        for (final b in past)
          ListTile(
            dense: true,
            title: Text('${b['plate']} · ${formatSlot(_t(b['slot_start']))}'),
            subtitle: Text([b['service'], BookingStatus.parse(b['status'] as String).label].whereType<String>().join(' · ')),
          ),
      ],
    ]);
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({required this.api, required this.station, required this.data, required this.b, required this.onChanged});
  final StationApi api;
  final LinkedStation station;
  final Map<String, dynamic> data;
  final Map<String, dynamic> b;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final slot = _t(b['slot_start']);
    final canChange = customerCanChange(slot, DateTime.now());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(formatSlot(slot), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text([b['plate'], b['service'], b['note']].whereType<String>().join(' · ')),
          const SizedBox(height: 8),
          if (!canChange)
            const Text('Too late to change online — call the station', style: TextStyle(fontSize: 12))
          else
            Row(children: [
              OutlinedButton(
                onPressed: () async {
                  final ok = await Navigator.push<bool>(
                      context, MaterialPageRoute(builder: (_) => BookSlotScreen(api: api, station: station, data: data, rescheduleId: b['id'] as String)));
                  if (ok == true) onChanged();
                },
                child: const Text('Reschedule'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      content: const Text('Cancel this booking?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel booking')),
                      ],
                    ),
                  );
                  if (yes != true || !context.mounted) return;
                  try {
                    await _run(context, () => api.cancelMyBooking(b['id'] as String), success: 'Booking cancelled');
                    onChanged();
                  } catch (_) {}
                },
                child: const Text('Cancel'),
              ),
            ]),
        ]),
      ),
    );
  }
}

/// SCR-042 — pick vehicle, service, date and a free slot; or move an existing booking.
class BookSlotScreen extends StatefulWidget {
  const BookSlotScreen({super.key, required this.api, required this.station, required this.data, this.rescheduleId});
  final StationApi api;
  final LinkedStation station;
  final Map<String, dynamic> data;
  final String? rescheduleId;

  @override
  State<BookSlotScreen> createState() => _BookSlotScreenState();
}

class _BookSlotScreenState extends State<BookSlotScreen> {
  late List<Map<String, dynamic>> _vehicles = _list(widget.data, 'vehicles');
  late final _services = _list(widget.data, 'services');
  late String? _vehicle = _vehicles.isEmpty ? null : _vehicles.first['id'] as String;
  String? _service;
  DateTime _day = DateTime.now();
  Future<List<Slot>>? _slots;
  DateTime? _slot;
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSlots();
  }

  void _loadSlots() => setState(() {
        _slot = null;
        _slots = widget.api.slots(widget.station.stationId, _day);
      });

  Future<void> _addVehicle() async {
    final plate = TextEditingController();
    final make = TextEditingController();
    final model = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add vehicle'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: plate, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Number plate', hintText: 'LEA-1234')),
          TextField(controller: make, decoration: const InputDecoration(labelText: 'Make (e.g. Toyota)')),
          TextField(controller: model, decoration: const InputDecoration(labelText: 'Model (e.g. Corolla)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final id = await widget.api.addMyVehicle(widget.station.stationId, plate: plate.text, make: make.text, model: model.text);
      setState(() {
        _vehicles = [..._vehicles, {'id': id, 'plate': normalizePlate(plate.text) ?? plate.text}];
        _vehicle = id;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _confirm() async {
    if (_slot == null) return;
    setState(() { _busy = true; });
    try {
      if (widget.rescheduleId != null) {
        await widget.api.rescheduleMyBooking(widget.rescheduleId!, _slot!);
      } else {
        await widget.api.book(widget.station.stationId, vehicleId: _vehicle!, serviceId: _service, slot: _slot!, note: _note.text);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Booked for ${formatSlot(_slot!)}')));
      Navigator.pop(context, true);
    } on AppError catch (e) {
      if (!mounted) return;
      showError(context, e);
      if (e.code == AppErrorCode.slotTaken) _loadSlots(); // "Slot just filled, pick another"
    } finally {
      if (mounted) setState(() { _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final moving = widget.rescheduleId != null;
    return Scaffold(
      appBar: AppBar(title: Text(moving ? 'Reschedule' : 'Book a slot')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!moving) ...[
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _vehicle,
                decoration: const InputDecoration(labelText: 'Vehicle'),
                items: [for (final v in _vehicles) DropdownMenuItem(value: v['id'] as String, child: Text(v['plate'] as String))],
                onChanged: (v) => setState(() { _vehicle = v; }),
              ),
            ),
            IconButton(tooltip: 'Add vehicle', onPressed: _addVehicle, icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 12),
          if (_services.isNotEmpty)
            DropdownButtonFormField<String?>(
              initialValue: _service,
              decoration: const InputDecoration(labelText: 'Service'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Not sure / inspection')),
                for (final s in _services) DropdownMenuItem<String?>(value: s['id'] as String, child: Text('${s['name']} · ${formatPkr(_m(s['rate_paisa']))}')),
              ],
              onChanged: (v) => setState(() { _service = v; }),
            ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          icon: const Icon(Icons.event),
          label: Text('${weekdayNames[_day.weekday - 1]} ${formatDate(_day)}'),
          onPressed: () async {
            final p = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 30)));
            if (p != null) {
              _day = p;
              _loadSlots();
            }
          },
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Slot>>(
          future: _slots,
          builder: (context, snap) {
            if (snap.hasError) return Text(snap.error is AppError ? (snap.error! as AppError).message : 'Could not load slots');
            if (!snap.hasData) return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
            final slots = snap.data!;
            if (slots.isEmpty) return const Text('No free slots on this day — pick another day');
            return Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in slots)
                ChoiceChip(
                  label: Text(formatHm(toPkt(s.start).hour * 60 + toPkt(s.start).minute)),
                  selected: _slot == s.start,
                  onSelected: (_) => setState(() { _slot = s.start; }),
                ),
            ]);
          },
        ),
        if (!moving) ...[
          const SizedBox(height: 12),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note for the station (optional)')),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _slot == null || (!moving && _vehicle == null) ? null : _confirm,
          child: Text(moving ? 'Move booking' : 'Confirm booking'),
        ),
        if (!moving && _vehicles.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Add your vehicle first (+ above).')),
      ]),
    );
  }
}

// ---- Jobs and approvals (REQ-020, REQ-022) -----------------------------------------------------
class _JobsTab extends StatelessWidget {
  const _JobsTab({required this.api, required this.data, required this.onChanged});
  final StationApi api;
  final Map<String, dynamic> data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final jobs = _list(data, 'jobs');
    if (jobs.isEmpty) return const Center(child: Text('No job cards yet'));
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final j in jobs)
        Card(
          child: ListTile(
            title: Text('Job #${j['job_no']} · ${j['plate']}'),
            subtitle: Text([
              JobStage.parse(j['stage'] as String).label,
              formatDate(_t(j['created_at']).toLocal()),
              if (j['stage'] == 'awaiting_approval') 'Estimate waiting for you',
              if (j['extra_pending'] == true) 'Extra work waiting for you',
            ].join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => JobTrackScreen(api: api, jobId: j['id'] as String)));
              onChanged();
            },
          ),
        ),
    ]);
  }
}

/// SCR-043 — stage timeline, estimate and extra work with Approve / Reject.
class JobTrackScreen extends StatefulWidget {
  const JobTrackScreen({super.key, required this.api, required this.jobId});
  final StationApi api;
  final String jobId;

  @override
  State<JobTrackScreen> createState() => _JobTrackScreenState();
}

class _JobTrackScreenState extends State<JobTrackScreen> {
  late Future<Map<String, dynamic>> _job;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() { _job = widget.api.myJob(widget.jobId); });

  Future<void> _decide(bool approve, bool extra, Money total) async {
    final what = extra ? 'extra work' : 'estimate';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(approve ? 'Approve $what?' : 'Reject $what?'),
        content: Text(approve
            ? 'Total ${formatPkr(total)}. The station will start the work.'
            : extra
                ? 'The extra work will not be done or billed.'
                : 'The job will be cancelled. An inspection fee may apply.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(approve ? 'Approve' : 'Reject')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await _run(context, () => widget.api.decide(widget.jobId, approve: approve, extra: extra), success: approve ? 'Approved' : 'Rejected');
    } catch (_) {}
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Job tracking')),
        body: AsyncStateView<Map<String, dynamic>>(
          future: _job,
          onRetry: _reload,
          builder: (context, j) {
            final stage = JobStage.parse(j['stage'] as String);
            final lines = _list(j, 'lines');
            final timeline = _list(j, 'timeline');
            final estimate = lines.where((l) => l['status'] == 'estimate').toList();
            final extra = lines.where((l) => l['status'] == 'extra_pending').toList();
            Money sum(List<Map<String, dynamic>> l) => l.fold(Money.zero, (s, x) => s + _m(x['total_paisa']));
            final invoice = j['invoice'] as Map<String, dynamic>?;
            return ListView(padding: const EdgeInsets.all(16), children: [
              Text('Job #${j['job_no']} · ${j['plate']}', style: Theme.of(context).textTheme.titleLarge),
              Text('${j['station_name']} · ${stage.label}'),
              if (j['approved_via'] == 'app' && j['approved_at'] != null)
                Text('Approved by you in the app on ${formatDate(_t(j['approved_at']).toLocal())} ${formatTime(_t(j['approved_at']).toLocal())}'),
              if (j['cancel_reason'] != null) Text('Cancelled: ${j['cancel_reason']}'),
              const SizedBox(height: 16),
              if (stage == JobStage.awaitingApproval && estimate.isNotEmpty)
                _ApprovalCard(
                  title: 'Estimate',
                  lines: estimate,
                  total: sum(estimate),
                  onApprove: () => _decide(true, false, sum(estimate)),
                  onReject: () => _decide(false, false, sum(estimate)),
                ),
              if (extra.isNotEmpty)
                _ApprovalCard(
                  title: 'Additional work',
                  lines: extra,
                  total: sum(extra),
                  onApprove: () => _decide(true, true, sum(extra)),
                  onReject: () => _decide(false, true, sum(extra)),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Progress', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    for (final t in timeline)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          const Icon(Icons.check_circle, size: 18, color: Color(0xFF16A34A)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(JobStage.parse(t['stage'] as String).label)),
                          Text('${formatDate(_t(t['at']).toLocal())} ${formatTime(_t(t['at']).toLocal())}', style: const TextStyle(fontSize: 12)),
                        ]),
                      ),
                  ]),
                ),
              ),
              if (lines.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Text('Work and parts', style: TextStyle(fontWeight: FontWeight.w700)),
                      for (final l in lines)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(l['description'] as String),
                          subtitle: Text('${l['qty']} × ${formatPkr(_m(l['unit_price_paisa']))} · ${LineStatus.parse(l['status'] as String).label}'),
                          trailing: Text(formatPkr(_m(l['total_paisa']))),
                        ),
                    ]),
                  ),
                ),
              if (invoice != null)
                Card(
                  child: ListTile(
                    title: Text('Invoice #${invoice['invoice_no']} · ${formatPkr(_m(invoice['total_paisa']))}'),
                    subtitle: Text('Paid ${formatPkr(_m(invoice['paid_paisa']))} · Due ${formatPkr(_m(invoice['due_paisa']))}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push<void>(context, MaterialPageRoute(builder: (_) => InvoiceScreen(api: widget.api, invoiceId: invoice['id'] as String))),
                  ),
                ),
              if (j['next_service_date'] != null || j['next_service_km'] != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.alarm),
                    title: const Text('Next service'),
                    subtitle: Text([
                      if (j['next_service_date'] != null) formatDate(DateTime.parse(j['next_service_date'] as String)),
                      if (j['next_service_km'] != null) 'at ${j['next_service_km']} km',
                    ].join(' or ')),
                  ),
                ),
            ]);
          },
        ),
      );
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.title, required this.lines, required this.total, required this.onApprove, required this.onReject});
  final String title;
  final List<Map<String, dynamic>> lines;
  final Money total;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('$title — waiting for your approval', style: const TextStyle(fontWeight: FontWeight.w700)),
            for (final l in lines)
              Row(children: [Expanded(child: Text(l['description'] as String)), Text(formatPkr(_m(l['total_paisa'])))]),
            const Divider(),
            Row(children: [const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))), Text(formatPkr(total), style: const TextStyle(fontWeight: FontWeight.w700))]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: onReject, child: const Text('Reject'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: onApprove, child: const Text('Approve'))),
            ]),
          ]),
        ),
      );
}

// ---- Invoices and history (SCR-044, REQ-048) -----------------------------------------------------
class _InvoicesTab extends StatelessWidget {
  const _InvoicesTab({required this.api, required this.data});
  final StationApi api;
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final invoices = _list(data, 'invoices');
    final dues = _m(data['dues_paisa']);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          title: const Text('Dues at this station'),
          trailing: Text(formatPkr(dues), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: dues.paisa > 0 ? const Color(0xFFDC2626) : null)),
        ),
      ),
      if (invoices.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No invoices yet')),
      for (final i in invoices)
        ListTile(
          title: Text('Invoice #${i['invoice_no']} · Job #${i['job_no']} · ${i['plate']}'),
          subtitle: Text('${formatDate(_t(i['issued_at']).toLocal())} · ${(i['status'] as String).replaceAll('_', ' ')}'),
          trailing: Text(formatPkr(_m(i['total_paisa']))),
          onTap: () => Navigator.push<void>(context, MaterialPageRoute(builder: (_) => InvoiceScreen(api: api, invoiceId: i['id'] as String))),
        ),
    ]);
  }
}

class InvoiceScreen extends StatelessWidget {
  const InvoiceScreen({super.key, required this.api, required this.invoiceId});
  final StationApi api;
  final String invoiceId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Invoice')),
        body: AsyncStateView<Map<String, dynamic>>(
          future: api.myInvoice(invoiceId),
          builder: (context, i) {
            final st = i['station'] as Map<String, dynamic>;
            final bal = i['balance'] as Map<String, dynamic>? ?? const {};
            Widget row(String k, Money v, {bool bold = false}) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(child: Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w800 : null))),
                    Text(formatPkr(v), style: TextStyle(fontWeight: bold ? FontWeight.w800 : null)),
                  ]),
                );
            return ListView(padding: const EdgeInsets.all(16), children: [
              Text(st['name'] as String, style: Theme.of(context).textTheme.titleLarge),
              Text([st['address'], st['city'], st['phone'], if (st['ntn'] != null) 'NTN ${st['ntn']}'].whereType<String>().join(' · ')),
              const Divider(height: 24),
              Text('Invoice #${i['invoice_no']} · Job #${i['job_no']} · ${i['plate']}'),
              Text('${i['customer']} · ${formatDate(_t(i['issued_at']).toLocal())}'),
              const SizedBox(height: 12),
              for (final l in (i['lines'] as List).cast<Map<String, dynamic>>())
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l['description'] as String),
                  subtitle: Text([
                    '${l['qty']} × ${formatPkr(_m(l['unit_price_paisa']))}',
                    if ((l['warranty_days'] as int? ?? 0) > 0) 'warranty ${l['warranty_days']} days',
                  ].join(' · ')),
                  trailing: Text(formatPkr(_m(l['total_paisa']))),
                ),
              const Divider(),
              row('Parts', _m(i['parts_paisa'])),
              row('Labour & services', _m(i['labour_paisa'])),
              if (_m(i['discount_paisa']).paisa > 0) row('Discount', Money.paisa(-_m(i['discount_paisa']).paisa)),
              if (_m(i['tax_paisa']).paisa > 0) row('Sales tax', _m(i['tax_paisa'])),
              row('Total', _m(i['total_paisa']), bold: true),
              row('Paid', _m(bal['paid_paisa'])),
              row('Due', _m(bal['due_paisa']), bold: true),
            ]);
          },
        ),
      );
}

class _VehiclesTab extends StatelessWidget {
  const _VehiclesTab({required this.api, required this.station, required this.data, required this.onChanged});
  final StationApi api;
  final LinkedStation station;
  final Map<String, dynamic> data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final vehicles = _list(data, 'vehicles');
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (vehicles.isEmpty) const Text('No vehicles yet. Add one when you book.'),
      for (final v in vehicles)
        Card(
          child: ListTile(
            leading: const Icon(Icons.directions_car_outlined),
            title: Text(v['plate'] as String),
            subtitle: Text([v['make'], v['model']].whereType<String>().join(' ')),
            trailing: const Text('History'),
            onTap: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text('${v['plate']} — service history')),
                  body: AsyncStateView<List<Map<String, dynamic>>>(
                    future: api.myVehicleHistory(v['id'] as String),
                    isEmpty: (l) => l.isEmpty,
                    emptyText: 'No visits yet',
                    builder: (context, rows) => ListView(children: [
                      for (final r in rows)
                        ListTile(
                          title: Text(r['title'] as String),
                          subtitle: Text([formatDate(_t(r['at']).toLocal()), if (r['odometer'] != null) '${r['odometer']} km'].join(' · ')),
                          trailing: r['total_paisa'] == null ? null : Text(formatPkr(_m(r['total_paisa']))),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}
