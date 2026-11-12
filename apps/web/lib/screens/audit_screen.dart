import 'dart:convert';

import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';

/// SCR-018 — REQ-058 owner-only audit log (Standard+; gated by the shell).
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  static const _tables = {null: 'All records', 'stations': 'Station settings', 'station_members': 'Users', 'subscriptions': 'Subscription', 'support_grants': 'Support access'};
  String? _table;
  late Future<List<AuditEntry>> _entries;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    setState(() => _entries = s.api.auditLog(s.current!.stationId, table: _table));
  }

  static String _value(Object? v) => v == null ? '—' : (v is String ? v : jsonEncode(v));

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Text('Audit log', style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          DropdownButton<String?>(
            value: _table,
            items: _tables.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
            onChanged: (v) {
              _table = v;
              _reload();
            },
          ),
        ]),
      ),
      Expanded(
        child: AsyncStateView<List<AuditEntry>>(
          future: _entries,
          onRetry: _reload,
          isEmpty: (l) => l.isEmpty,
          emptyText: 'No entries yet',
          builder: (context, entries) => ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = entries[i];
              final at = e.at.toLocal();
              final lines = e.action == 'update'
                  ? e.changes.entries.map((c) {
                      final m = c.value as Map;
                      return '${c.key}: ${_value(m['old'])} → ${_value(m['new'])}';
                    }).toList()
                  : <String>[];
              return ListTile(
                title: Text('${_tables[e.table] ?? e.table} · ${e.action}'),
                subtitle: Text([...lines, '${formatDate(at)} ${formatTime(at)}'].join('\n')),
                isThreeLine: lines.isNotEmpty,
              );
            },
          ),
        ),
      ),
    ]);
  }
}
