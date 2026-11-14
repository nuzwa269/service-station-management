import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';

/// SCR-013 — REQ-044: expected per payment method vs counted cash; difference needs a note.
class DayClosingScreen extends StatefulWidget {
  const DayClosingScreen({super.key});

  @override
  State<DayClosingScreen> createState() => _DayClosingScreenState();
}

class _DayClosingScreenState extends State<DayClosingScreen> {
  DateTime _day = DateTime.now();
  late Future<DaySummary> _summary;
  late Future<List<Map<String, dynamic>>> _history;
  final _counted = TextEditingController();
  final _note = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    setState(() {
      _summary = s.api.daySummary(s.current!.stationId, _day);
      _history = s.api.recentClosings(s.current!.stationId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final owner = s.role == MemberRole.owner;
    return ListView(padding: const EdgeInsets.all(16), children: [
      PageHeader(title: 'Day closing', actions: [
        OutlinedButton.icon(
          onPressed: () async {
            final d = await showDatePicker(context: context, firstDate: DateTime(2026), lastDate: DateTime.now(), initialDate: _day);
            if (d != null) {
              _day = d;
              _reload();
            }
          },
          icon: const Icon(Icons.calendar_month_rounded),
          label: Text(formatDateLong(_day)),
        ),
      ]),
      AsyncStateView<DaySummary>(
        future: _summary,
        onRetry: _reload,
        builder: (context, d) {
          final counted = parsePkr(_counted.text);
          final diff = counted == null ? null : counted - d.expectedCash;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final m in PayMethod.receivable)
                SizedBox(
                  width: 200,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m.label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 6),
                        Text(formatPkr(d.expected[m] ?? Money.zero), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Text('${d.count} payment entries (refunds and reversals included).'),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: d.closed
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.lock_rounded, color: Color(0xFF16A34A)),
                          const SizedBox(width: 8),
                          Text('Closed — counted ${formatPkr(Money.paisa((d.closing!['counted_cash'] as num).toInt()))}, '
                              'difference ${formatPkr(Money.paisa((d.closing!['difference'] as num).toInt()))}'),
                        ]),
                        if (d.closing!['note'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Note: ${d.closing!['note']}')),
                        if (owner) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final reason = await askReason(context, title: 'Reopen ${formatDate(_day)}');
                              if (reason == null || !context.mounted) return;
                              if (await runAction(context, () => s.api.reopenDay(s.current!.stationId, _day, reason), success: 'Day reopened')) _reload();
                            },
                            icon: const Icon(Icons.lock_open_rounded),
                            label: const Text('Reopen day'),
                          ),
                        ],
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Text('Count the cash in the drawer', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        Row(children: [
                          SizedBox(
                            width: 220,
                            child: TextField(
                              controller: _counted,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(labelText: 'Counted cash (Rs)', helperText: 'Expected ${formatPkr(d.expectedCash)}'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          if (diff != null)
                            Text('Difference: ${diff.isNegative ? '' : '+'}${formatPkr(diff)}',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: diff.paisa == 0 ? const Color(0xFF16A34A) : const Color(0xFFDC2626))),
                        ]),
                        const SizedBox(height: 10),
                        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (required if there is a difference)')),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            onPressed: counted == null
                                ? null
                                : () async {
                                    if (await runAction(context, () => s.api.closeDay(s.current!.stationId, _day, counted, note: _note.text),
                                        success: 'Day closed')) {
                                      _counted.clear();
                                      _note.clear();
                                      _reload();
                                    }
                                  },
                            icon: const Icon(Icons.lock_rounded),
                            label: const Text('Close day'),
                          ),
                        ),
                      ]),
              ),
            ),
          ]);
        },
      ),
      const SizedBox(height: 20),
      const Text('Recent closings', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      AsyncStateView<List<Map<String, dynamic>>>(
        future: _history,
        isEmpty: (l) => l.isEmpty,
        emptyText: 'No days closed yet',
        builder: (context, rows) => Column(children: [
          for (final r in rows)
            ListTile(
              dense: true,
              leading: Icon(r['reopened_at'] == null ? Icons.lock_rounded : Icons.lock_open_rounded, size: 18),
              title: Text(formatDateLong(DateTime.parse(r['day'] as String))),
              subtitle: Text(r['reopened_at'] == null ? (r['note'] as String? ?? '') : 'Reopened: ${r['reopen_reason']}'),
              trailing: Text('Diff ${formatPkr(Money.paisa((r['difference'] as num).toInt()))}'),
            ),
        ]),
      ),
    ]);
  }
}
