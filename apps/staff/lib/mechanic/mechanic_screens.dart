import 'dart:async';

import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../sync/own_sync_engine.dart';

/// SCR-031 / SCR-032 / SCR-033 — mechanic work, online or offline (REQ-021, REQ-023).
class MechanicHome extends StatefulWidget {
  const MechanicHome({super.key, required this.engine, required this.stationName, required this.onSignOut, this.autoSync = true});
  final OwnSyncEngine engine;
  final String stationName;
  final VoidCallback onSignOut;
  final bool autoSync;

  @override
  State<MechanicHome> createState() => _MechanicHomeState();
}

class _MechanicHomeState extends State<MechanicHome> {
  SyncStatus? _status;
  StreamSubscription<SyncStatus>? _sub;
  Timer? _timer;
  String? _openJob;

  OwnSyncEngine get e => widget.engine;

  @override
  void initState() {
    super.initState();
    _sub = e.status.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    e.start().then((_) => e.syncNow());
    if (widget.autoSync) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => e.syncNow());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  List<Map<String, dynamic>> _list(String k) => [for (final x in (e.snapshot[k] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];

  @override
  Widget build(BuildContext context) {
    final jobs = _list('jobs');
    final job = _openJob == null ? null : jobs.where((j) => j['id'] == _openJob).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        leading: job == null ? null : IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => setState(() => _openJob = null)),
        title: Text(job == null ? 'My jobs' : 'Job #${job['job_no']}'),
        actions: [
          SyncBadge(status: _status, onTap: () => _showSync(context)),
          if (job == null) IconButton(tooltip: 'Log out', onPressed: widget.onSignOut, icon: const Icon(Icons.logout_rounded)),
        ],
      ),
      body: Column(children: [
        if (_status != null && _status!.overdue(DateTime.now()))
          MaterialBanner(
            backgroundColor: const Color(0xFFFFF7ED),
            content: const Text('Connect to sync — changes older than 24 h are at risk'),
            actions: [TextButton(onPressed: e.syncNow, child: const Text('Sync now'))],
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await e.syncNow();
              if (mounted) setState(() {});
            },
            child: job == null ? _jobsList(jobs) : JobWorkView(engine: e, job: job, onChanged: () => setState(() {})),
          ),
        ),
      ]),
    );
  }

  Widget _jobsList(List<Map<String, dynamic>> jobs) {
    if (jobs.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 120),
        Icon(Icons.assignment_turned_in_rounded, size: 48, color: Color(0xFF94A3B8)),
        SizedBox(height: 12),
        Center(child: Text('No jobs assigned to you right now')),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: jobs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final j = jobs[i];
        final stage = JobStage.parse(j['stage'] as String);
        return Card(
          child: ListTile(
            key: Key('job-${j['job_no']}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            title: Text('#${j['job_no']} · ${j['plate']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text([
              [j['make'], j['model']].whereType<String>().join(' '),
              if ((j['complaints'] as String?)?.isNotEmpty ?? false) j['complaints'],
            ].join('\n')),
            trailing: _StagePill(stage),
            onTap: () => setState(() => _openJob = j['id'] as String),
          ),
        );
      },
    );
  }

  Future<void> _showSync(BuildContext context) async {
    final q = await e.store.queue();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sync status', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(_status?.online ?? false ? 'Online' : 'Offline — changes are saved on this phone'),
            Text('Pending changes: ${q.length}${q.any((c) => c.held) ? ' (${q.where((c) => c.held).length} held: subscription read-only)' : ''}'),
            Text('Last sync: ${_status?.lastSyncAt == null ? 'never' : '${formatDate(_status!.lastSyncAt!.toLocal())} ${formatTime(_status!.lastSyncAt!.toLocal())}'}'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await e.syncNow();
              },
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Sync now'),
            ),
          ]),
        ),
      ),
    );
  }
}

class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, required this.status, required this.onTap});
  final SyncStatus? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final offline = s != null && !s.online;
    final pending = s?.pendingCount ?? 0;
    final color = offline ? const Color(0xFFEA580C) : (pending > 0 ? const Color(0xFF0EA5E9) : const Color(0xFF16A34A));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: ActionChip(
        key: const Key('sync-badge'),
        onPressed: onTap,
        avatar: Icon(offline ? Icons.cloud_off_rounded : (pending > 0 ? Icons.cloud_upload_rounded : Icons.cloud_done_rounded), size: 18, color: color),
        label: Text(offline ? 'Offline · $pending' : (pending > 0 ? '$pending pending' : 'Synced')),
      ),
    );
  }
}

class _StagePill extends StatelessWidget {
  const _StagePill(this.stage);
  final JobStage stage;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFE0F2FE), borderRadius: BorderRadius.circular(20)),
        child: Text(stage.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF0369A1))),
      );
}

/// SCR-032 — complaints, checklist, parts used, stage buttons. Every tap goes to the queue.
class JobWorkView extends StatelessWidget {
  const JobWorkView({super.key, required this.engine, required this.job, required this.onChanged});
  final OwnSyncEngine engine;
  final Map<String, dynamic> job;
  final VoidCallback onChanged;

  List<Map<String, dynamic>> _list(String k) => [for (final x in (engine.snapshot[k] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];

  Future<void> _do(String op, Map<String, Object?> args) async {
    await engine.enqueue(op, args);
    onChanged();
    unawaited(engine.syncNow().then((_) => onChanged()));
  }

  Future<void> _addPart(BuildContext context) async {
    final items = _list('items');
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PartPicker(items: items),
    );
    if (picked == null || !context.mounted) return;
    final unit = ItemUnit.parse(picked['unit'] as String);
    final qtyText = TextEditingController(text: '1');
    final qty = await showDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(picked['name'] as String),
        content: TextField(controller: qtyText, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Quantity (${unit.short})')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final n = num.tryParse(qtyText.text.trim());
              if (n == null || n <= 0 || !isValidQty(unit, n)) return;
              Navigator.pop(ctx, n);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (qty == null) return;
    await _do('part_add', {'line_id': engine.newId(), 'job_id': job['id'], 'item_id': picked['id'], 'qty': qty});
  }

  @override
  Widget build(BuildContext context) {
    final stage = JobStage.parse(job['stage'] as String);
    final checklist = _list('checklist').where((c) => c['job_id'] == job['id']).toList();
    final lines = _list('lines').where((l) => l['job_id'] == job['id']).toList();
    final unchecked = checklist.where((c) => c['status'] == 'not_checked').length;
    final next = stage.mechanicNext;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${job['plate']} · ${[job['make'], job['model']].whereType<String>().join(' ')}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              _StagePill(stage),
            ]),
            const SizedBox(height: 6),
            Text('Customer: ${job['customer_name']} · ${job['odometer_km']} km'),
            if ((job['complaints'] as String?)?.isNotEmpty ?? false) ...[const SizedBox(height: 8), Text('Complaints: ${job['complaints']}')],
            if (job['qc_note'] != null && stage == JobStage.inProgress) ...[
              const SizedBox(height: 8),
              Text('Quality check note: ${job['qc_note']}', style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 12),
      if (next != null)
        FilledButton.icon(
          key: const Key('stage-next'),
          onPressed: next == JobStage.qualityCheck && unchecked > 0 ? null : () => _do('stage', {'job_id': job['id'], 'stage': next.code}),
          icon: Icon(next == JobStage.inProgress ? Icons.play_arrow_rounded : Icons.rule_rounded),
          label: Text(next == JobStage.inProgress
              ? 'Start work'
              : unchecked > 0
                  ? 'Finish checklist ($unchecked left) to request QC'
                  : 'Request quality check'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
      if (stage == JobStage.qualityCheck)
        const Card(child: Padding(padding: EdgeInsets.all(14), child: Text('Waiting for the manager\'s quality check.'))),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Checklist', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            for (final c in checklist)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text(c['name'] as String)),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    emptySelectionAllowed: true,
                    segments: const [ButtonSegment(value: 'ok', label: Text('OK')), ButtonSegment(value: 'attention', label: Text('Attention'))],
                    selected: c['status'] == 'not_checked' ? {} : {c['status'] as String},
                    onSelectionChanged: stage == JobStage.qualityCheck
                        ? null
                        : (v) => _do('check', {'check_id': c['id'], 'status': v.isEmpty ? 'not_checked' : v.first, 'note': c['note']}),
                  ),
                ]),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Parts used', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
              if (stage != JobStage.qualityCheck)
                TextButton.icon(key: const Key('add-part'), onPressed: () => _addPart(context), icon: const Icon(Icons.add_rounded), label: const Text('Add part')),
            ]),
            if (lines.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No parts yet')),
            for (final l in lines)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(l['pending'] == true ? Icons.cloud_upload_rounded : Icons.settings_rounded, size: 20),
                title: Text('${l['description']} × ${l['qty']}'),
                subtitle: Text(l['status'] == 'extra_pending' ? 'Added by mechanic — awaiting customer approval' : 'In the approved estimate'),
                trailing: l['mine'] == true && stage != JobStage.qualityCheck
                    ? IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => _do('part_remove', {'line_id': l['id']}))
                    : null,
              ),
          ]),
        ),
      ),
    ]);
  }
}

class _PartPicker extends StatefulWidget {
  const _PartPicker({required this.items});
  final List<Map<String, dynamic>> items;

  @override
  State<_PartPicker> createState() => _PartPickerState();
}

class _PartPickerState extends State<_PartPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final shown = widget.items
        .where((i) => q.isEmpty || (i['name'] as String).toLowerCase().contains(q) || (i['code'] as String).toLowerCase().contains(q) || i['barcode'] == _q)
        .take(50)
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Part name, code or barcode'),
                onChanged: (v) => setState(() => _q = v.trim()),
              ),
            ),
            Expanded(
              child: ListView(children: [
                for (final i in shown)
                  ListTile(
                    title: Text(i['name'] as String),
                    subtitle: Text('${i['code']} · stock ${formatQty(i['on_hand'] as num, ItemUnit.parse(i['unit'] as String))}'),
                    onTap: () => Navigator.pop(context, i),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
