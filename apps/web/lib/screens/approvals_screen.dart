import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';

/// SCR-012 — REQ-057 approvals inbox (Standard+; gated by the shell).
class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends State<ApprovalsScreen> {
  late Future<List<ApprovalRequest>> _requests;
  bool _pendingOnly = true;
  bool? _managerCanApprove;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    setState(() => _requests = s.api.approvals(s.current!.stationId, pendingOnly: _pendingOnly));
    if (s.role == MemberRole.owner && _managerCanApprove == null) {
      s.api.station(s.current!.stationId).then((st) {
        if (mounted) setState(() => _managerCanApprove = st['manager_can_approve'] as bool? ?? true);
      });
    }
  }

  Future<void> _decide(ApprovalRequest r, bool approve) async {
    final s = SessionScope.of(context);
    final note = await askReason(context, title: approve ? 'Approve' : 'Reject', label: 'Note (optional)', required: false);
    if (note == null || !mounted) return;
    if (await runAction(context, () => s.api.decideApproval(r.id, approve, note: note), success: approve ? 'Approved' : 'Rejected')) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final me = s.api.userId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: 'Approvals', actions: [
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: true, label: Text('Pending')), ButtonSegment(value: false, label: Text('All'))],
          selected: {_pendingOnly},
          onSelectionChanged: (v) {
            _pendingOnly = v.first;
            _reload();
          },
        ),
        if (s.role == MemberRole.owner && _managerCanApprove != null)
          FilterChip(
            label: const Text('Managers can approve'),
            selected: _managerCanApprove!,
            onSelected: (v) async {
              if (await runAction(context, () => s.api.setManagerCanApprove(s.current!.stationId, v))) {
                setState(() => _managerCanApprove = v);
              }
            },
          ),
      ]),
      Expanded(
        child: AsyncStateView<List<ApprovalRequest>>(
          future: _requests,
          onRetry: _reload,
          isEmpty: (l) => l.isEmpty,
          emptyText: _pendingOnly ? 'No pending requests' : 'No requests yet',
          builder: (context, list) => ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = list[i];
              final at = r.createdAt.toLocal();
              final decided = r.status != 'pending';
              return ListTile(
                title: Text('${r.typeLabel} · ${r.summary}'),
                subtitle: Text([
                  'By ${r.requestedByName}, ${formatDate(at)} ${formatTime(at)} — ${r.reason}',
                  if (decided)
                    '${r.status == 'approved' ? 'Approved' : 'Rejected'} by ${r.decidedByName ?? ''}, '
                        '${formatDate(r.decidedAt!.toLocal())} ${formatTime(r.decidedAt!.toLocal())}'
                        '${r.decisionNote == null ? '' : ' — ${r.decisionNote}'}',
                ].join('\n')),
                isThreeLine: decided,
                trailing: decided || r.requestedBy == me
                    ? Chip(label: Text(decided ? r.status : 'waiting'))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        TextButton(onPressed: () => _decide(r, false), child: const Text('Reject')),
                        FilledButton(onPressed: () => _decide(r, true), child: const Text('Approve')),
                      ]),
              );
            },
          ),
        ),
      ),
    ]);
  }
}
