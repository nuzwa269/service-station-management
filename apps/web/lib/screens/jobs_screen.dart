import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';
import 'customers_screen.dart';
import 'job_detail.dart';

const stageColors = <JobStage, Color>{
  JobStage.intake: Color(0xFF64748B),
  JobStage.awaitingApproval: Color(0xFFF59E0B),
  JobStage.approved: Color(0xFF6366F1),
  JobStage.inProgress: Color(0xFF0EA5E9),
  JobStage.qualityCheck: Color(0xFFEC4899),
  JobStage.ready: Color(0xFF22C55E),
  JobStage.delivered: Color(0xFF94A3B8),
  JobStage.cancelled: Color(0xFFEF4444),
};

class StageChip extends StatelessWidget {
  const StageChip(this.stage, {super.key});
  final JobStage stage;

  @override
  Widget build(BuildContext context) {
    final c = stageColors[stage]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(stage.label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// SCR-005 / SCR-006 — job cards: stage filter on top, list on the left, the chosen job on the right.
class JobCardsScreen extends StatefulWidget {
  const JobCardsScreen({super.key});

  @override
  State<JobCardsScreen> createState() => _JobCardsScreenState();
}

enum _Filter { open, intake, awaiting, approved, inProgress, qc, ready, closed }

const _filterStages = <_Filter, Set<JobStage>>{
  _Filter.open: {JobStage.intake, JobStage.awaitingApproval, JobStage.approved, JobStage.inProgress, JobStage.qualityCheck, JobStage.ready},
  _Filter.intake: {JobStage.intake},
  _Filter.awaiting: {JobStage.awaitingApproval},
  _Filter.approved: {JobStage.approved},
  _Filter.inProgress: {JobStage.inProgress},
  _Filter.qc: {JobStage.qualityCheck},
  _Filter.ready: {JobStage.ready},
  _Filter.closed: {JobStage.delivered, JobStage.cancelled},
};

const _filterLabels = <_Filter, String>{
  _Filter.open: 'All open',
  _Filter.intake: 'Intake',
  _Filter.awaiting: 'Awaiting approval',
  _Filter.approved: 'Approved',
  _Filter.inProgress: 'In progress',
  _Filter.qc: 'Quality check',
  _Filter.ready: 'Ready',
  _Filter.closed: 'Delivered & cancelled',
};

class _JobCardsScreenState extends State<JobCardsScreen> {
  _Filter _filter = _Filter.open;
  late Future<List<JobSummary>> _jobs;
  Map<JobStage, int> _counts = const {};
  String? _selected;
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    setState(() => _jobs = s.api.jobs(id, stages: _filterStages[_filter]));
    s.api.jobCounts(id).then((c) {
      if (mounted) setState(() => _counts = c);
    }).catchError((_) {});
  }

  int _countFor(_Filter f) => f == _Filter.closed ? -1 : _filterStages[f]!.fold(0, (sum, s) => sum + (_counts[s] ?? 0));

  Future<void> _newJob() async {
    final id = await showDialog<String>(context: context, builder: (_) => const NewJobDialog());
    if (id != null) {
      _filter = _Filter.open;
      _selected = id;
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: TextField(
          decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Job no, plate or customer'),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
      ),
      Expanded(
        child: AsyncStateView<List<JobSummary>>(
          future: _jobs,
          onRetry: _reload,
          isEmpty: (l) => l.isEmpty,
          emptyText: _filter == _Filter.open ? 'No open job cards — New job card' : 'Nothing here',
          builder: (context, all) {
            final jobs = all
                .where((j) =>
                    _query.isEmpty ||
                    '${j.jobNo}'.contains(_query) ||
                    j.plate.toLowerCase().replaceAll('-', '').contains(_query.replaceAll('-', '')) ||
                    j.customerName.toLowerCase().contains(_query))
                .toList();
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: jobs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _JobTile(job: jobs[i], selected: jobs[i].id == _selected, onTap: () => setState(() => _selected = jobs[i].id)),
            );
          },
        ),
      ),
    ]);

    final detail = _selected == null
        ? const Center(child: Text('Select a job card'))
        : JobDetailView(
            key: ValueKey(_selected),
            jobId: _selected!,
            onChanged: _reload,
            onOpenJob: (id) => setState(() => _selected = id),
            onClose: wide ? null : () => setState(() => _selected = null),
          );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: 'Job cards', actions: [
        FilledButton.icon(onPressed: _newJob, icon: const Icon(Icons.add_task_rounded), label: const Text('New job card')),
      ]),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(_countFor(f) < 0 ? _filterLabels[f]! : '${_filterLabels[f]}  ${_countFor(f)}'),
                selected: f == _filter,
                onSelected: (_) {
                  _filter = f;
                  _reload();
                },
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(width: 380, child: list),
                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 0, 16, 16), child: detail)),
              ])
            : (_selected == null ? list : detail),
      ),
    ]);
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.selected, required this.onTap});
  final JobSummary job;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('#${job.jobNo}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              if (job.kind != 'normal') ...[
                const SizedBox(width: 6),
                Text(job.kind == 'rework' ? 'Rework' : 'Warranty', style: TextStyle(fontSize: 11, color: scheme.tertiary, fontWeight: FontWeight.w700)),
              ],
              const Spacer(),
              StageChip(job.stage),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.directions_car_rounded, size: 16, color: Color(0xFF64748B)),
              const SizedBox(width: 6),
              Text(job.plate, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(child: Text(job.vehicleName ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))),
            ]),
            const SizedBox(height: 4),
            Text(job.customerName, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            if (job.mechanics.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.engineering_rounded, size: 15, color: Color(0xFF64748B)),
                const SizedBox(width: 6),
                Expanded(child: Text(job.mechanics.join(', '), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

/// REQ-018 — intake: find or add the customer, choose the vehicle, odometer, fuel, complaints.
class NewJobDialog extends StatefulWidget {
  const NewJobDialog({super.key});

  @override
  State<NewJobDialog> createState() => _NewJobDialogState();
}

class _NewJobDialogState extends State<NewJobDialog> {
  final _search = TextEditingController();
  final _odometer = TextEditingController();
  final _complaints = TextEditingController();
  List<CustomerHit> _hits = const [];
  CustomerHit? _picked;
  FuelLevel _fuel = FuelLevel.half;
  DateTime? _expected;
  bool _busy = false;

  Future<void> _find() async {
    final s = SessionScope.of(context);
    if (_search.text.trim().length < 2) return;
    final hits = await s.api.searchCustomers(s.current!.stationId, _search.text.trim());
    if (mounted) setState(() => _hits = hits.where((h) => h.vehicleId != null).toList());
  }

  Future<void> _addCustomer() async {
    final id = await showDialog<String>(context: context, builder: (_) => const CustomerDialog());
    if (id == null || !mounted) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => VehicleDialog(customerId: id));
    if (ok == true && mounted) {
      final s = SessionScope.of(context);
      final c = await s.api.customer(id);
      _search.text = c['mobile'] as String;
      await _find();
    }
  }

  Future<void> _save({bool confirm = false}) async {
    final s = SessionScope.of(context);
    final odo = int.tryParse(_odometer.text.replaceAll(',', '').trim());
    if (_picked == null || odo == null) {
      showError(context, const AppError(AppErrorCode.validation, 'Choose a vehicle and enter the odometer'));
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await s.api.createJob(s.current!.stationId,
          customerId: _picked!.customerId,
          vehicleId: _picked!.vehicleId!,
          odometer: odo,
          fuel: _fuel,
          complaints: _complaints.text,
          expectedDelivery: _expected,
          confirmOdometer: confirm);
      if (mounted) Navigator.pop(context, id);
    } on AppError catch (e) {
      if (!mounted) return;
      if (e.code == AppErrorCode.odometerLower) {
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Check the odometer'),
            content: Text(e.message),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Fix it')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm and save')),
            ],
          ),
        );
        if (yes == true) {
          setState(() => _busy = false);
          return _save(confirm: true);
        }
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New job card'),
      content: SizedBox(
        width: 560,
        child: ListView(shrinkWrap: true, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Customer phone, plate or name'),
                onChanged: (_) => _find(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: _addCustomer, icon: const Icon(Icons.person_add_alt_1_rounded), label: const Text('New')),
          ]),
          const SizedBox(height: 8),
          for (final h in _hits.take(6))
            ListTile(
              leading: Icon(
                h.vehicleId == _picked?.vehicleId ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                color: h.vehicleId == _picked?.vehicleId ? Theme.of(context).colorScheme.primary : null,
              ),
              onTap: () => setState(() => _picked = h),
              title: Text('${h.plate} · ${h.name}'),
              subtitle: Text([formatPkMobile(h.mobile), if (h.make != null) '${h.make} ${h.model ?? ''}'].join(' · ')),
              dense: true,
            ),
          if (_hits.isEmpty && _search.text.trim().length >= 2)
            const Padding(padding: EdgeInsets.all(8), child: Text('No vehicle found — add a new customer')),
          const Divider(height: 24),
          Row(children: [
            Expanded(
              child: TextField(controller: _odometer, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Odometer (km)')),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 60)), initialDate: now);
                  if (d == null || !context.mounted) return;
                  final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 17, minute: 0));
                  setState(() => _expected = DateTime(d.year, d.month, d.day, t?.hour ?? 17, t?.minute ?? 0));
                },
                icon: const Icon(Icons.schedule_rounded),
                label: Text(_expected == null ? 'Expected delivery' : '${formatDate(_expected!)} ${formatTime(_expected!)}'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          const Text('Fuel level'),
          const SizedBox(height: 6),
          SegmentedButton<FuelLevel>(
            segments: [for (final f in FuelLevel.values) ButtonSegment(value: f, label: Text(f.label))],
            selected: {_fuel},
            onSelectionChanged: (v) => setState(() => _fuel = v.first),
          ),
          const SizedBox(height: 12),
          TextField(controller: _complaints, maxLines: 3, decoration: const InputDecoration(labelText: 'Complaints')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Create job card')),
      ],
    );
  }
}

/// Small helper reused by job actions.
Future<bool> confirmAction(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
        ],
      ),
    ) ==
    true;

// Re-exported so job_detail.dart can use runAction without importing common twice.
Future<bool> runJobAction(BuildContext context, Future<void> Function() action, {String? success}) => runAction(context, action, success: success);
