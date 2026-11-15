import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';

/// SCR-004 — bookings calendar: one day per view, slots with bay capacity, new booking,
/// reschedule, cancel, mark arrived (opens the job card), no-shows and settings conflicts.
class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _DayData {
  const _DayData(this.settings, this.slots, this.bookings, this.recent, this.conflicts);
  final BookingSettings settings;
  final List<Slot> slots;
  final List<Booking> bookings;
  final List<Booking> recent; // last 7 days, for the no-show list
  final List<Map<String, dynamic>> conflicts;
}

DateTime _pkToday() {
  final t = toPkt(DateTime.now());
  return DateTime(t.year, t.month, t.day);
}

/// Midnight of a Pakistan-time day as a UTC instant.
DateTime _pkMidnightUtc(DateTime day) => DateTime.utc(day.year, day.month, day.day).subtract(const Duration(hours: 5));

class _BookingsScreenState extends State<BookingsScreen> {
  DateTime _day = _pkToday();
  late Future<_DayData> _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    final from = _pkMidnightUtc(_day);
    setState(() {
      _data = () async {
        final settings = await s.api.bookingSettings(id);
        final slots = await s.api.slots(id, _day);
        final bookings = await s.api.bookings(id, from, from.add(const Duration(days: 1)));
        final today = _pkMidnightUtc(_pkToday());
        final recent = await s.api.bookings(id, today.subtract(const Duration(days: 7)), today.add(const Duration(days: 1)));
        final conflicts = await s.api.bookingConflicts(id);
        return _DayData(settings, slots, bookings, recent, conflicts);
      }();
    });
  }

  void _go(int days) {
    _day = _day.add(Duration(days: days));
    _reload();
  }

  Future<void> _pickDay() async {
    final p = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2025), lastDate: DateTime.now().add(const Duration(days: 365)));
    if (p != null) {
      _day = p;
      _reload();
    }
  }

  Future<void> _newBooking([DateTime? slot]) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => BookingDialog(initialDay: _day, initialSlot: slot));
    if (ok == true) _reload();
  }

  Future<void> _settings(BookingSettings current) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => BookingSettingsDialog(initial: current));
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final isOwner = s.role == MemberRole.owner;
    return AsyncStateView<_DayData>(
      future: _data,
      onRetry: _reload,
      builder: (context, d) {
        final header = PageHeader(title: 'Bookings', actions: [
          IconButton(tooltip: 'Previous day', onPressed: () => _go(-1), icon: const Icon(Icons.chevron_left)),
          OutlinedButton.icon(onPressed: _pickDay, icon: const Icon(Icons.event_outlined), label: Text('${weekdayNames[_day.weekday - 1]} ${formatDate(_day)}')),
          IconButton(tooltip: 'Next day', onPressed: () => _go(1), icon: const Icon(Icons.chevron_right)),
          TextButton(
              onPressed: () {
                _day = _pkToday();
                _reload();
              },
              child: const Text('Today')),
          FilledButton.icon(onPressed: d.settings.isSetUp ? () => _newBooking() : null, icon: const Icon(Icons.add), label: const Text('New booking')),
          if (isOwner) OutlinedButton.icon(onPressed: () => _settings(d.settings), icon: const Icon(Icons.tune), label: const Text('Booking settings')),
        ]);
        if (!d.settings.isSetUp) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header,
            Expanded(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.event_available_outlined, size: 48),
                  const SizedBox(height: 12),
                  const Text('Booking is not set up yet'),
                  const SizedBox(height: 8),
                  if (isOwner)
                    FilledButton(onPressed: () => _settings(d.settings), child: const Text('Set bays and working hours'))
                  else
                    const Text('Ask the owner to set bays and working hours.'),
                ]),
              ),
            ),
          ]);
        }
        final calendar = _DayCalendar(data: d, onNew: _newBooking, onChanged: _reload);
        final side = _SidePanel(data: d, onChanged: _reload);
        return LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 1000;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header,
            Expanded(
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 3, child: calendar),
                      SizedBox(width: 360, child: side),
                    ])
                  : ListView(children: [SizedBox(height: 600, child: calendar), side]),
            ),
          ]);
        });
      },
    );
  }
}

class _DayCalendar extends StatelessWidget {
  const _DayCalendar({required this.data, required this.onNew, required this.onChanged});
  final _DayData data;
  final void Function(DateTime slot) onNew;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (data.slots.isEmpty) {
      return const Center(child: Text('Closed on this day (off-day or no working hours)'));
    }
    // Bookings outside today's slots (e.g. after a settings change) still show.
    final starts = data.slots.map((s) => s.start).toSet();
    final orphans = data.bookings.where((b) => !starts.contains(b.slotStart)).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
      for (final slot in data.slots)
        _SlotCard(
          slot: slot,
          bookings: data.bookings.where((b) => b.slotStart == slot.start).toList(),
          onNew: () => onNew(slot.start),
          onChanged: onChanged,
        ),
      if (orphans.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.fromLTRB(4, 12, 0, 6), child: Text('Outside the current slots', style: TextStyle(fontWeight: FontWeight.w700))),
        for (final b in orphans) _BookingTile(b: b, onChanged: onChanged),
      ],
    ]);
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({required this.slot, required this.bookings, required this.onNew, required this.onChanged});
  final Slot slot;
  final List<Booking> bookings;
  final VoidCallback onNew;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final full = slot.booked >= slot.capacity;
    final t = toPkt(slot.start);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 92,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(formatHm(t.hour * 60 + t.minute), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              Text('${slot.booked}/${slot.capacity} bays', style: TextStyle(color: full ? const Color(0xFFDC2626) : scheme.onSurfaceVariant)),
            ]),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final b in bookings) _BookingTile(b: b, onChanged: onChanged),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: onNew, icon: const Icon(Icons.add, size: 18), label: Text(full ? 'Overbook' : 'Book')),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

const _statusColors = {
  BookingStatus.booked: Color(0xFF2563EB),
  BookingStatus.arrived: Color(0xFF16A34A),
  BookingStatus.noShow: Color(0xFFDC2626),
  BookingStatus.cancelled: Color(0xFF6B7280),
};

class _BookingTile extends StatelessWidget {
  const _BookingTile({required this.b, required this.onChanged});
  final Booking b;
  final VoidCallback onChanged;

  Future<void> _arrived(BuildContext context) async {
    final res = await showDialog<String>(context: context, builder: (_) => _ArrivedDialog(booking: b));
    if (res == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Job card opened')));
    context.go('/${MenuItem.jobCards.name}');
  }

  Future<void> _move(BuildContext context) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => BookingDialog(initialDay: DateTime.now(), existing: b));
    if (ok == true) onChanged();
  }

  Future<void> _cancel(BuildContext context) async {
    final reason = await askReason(context, title: 'Cancel booking ${b.plate}');
    if (reason == null || !context.mounted) return;
    if (await runAction(context, () => SessionScope.of(context).api.cancelBooking(b.id, reason), success: 'Booking cancelled')) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColors[b.status]!;
    final open = b.status == BookingStatus.booked || b.status == BookingStatus.noShow;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: color, width: 3)), color: color.withValues(alpha: 0.05)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${b.plate} · ${b.customerName ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              [
                if (b.mobile != null) formatPkMobile(b.mobile!),
                if (b.service != null) b.service!,
                b.source == 'app' ? 'App' : 'Staff',
                if (b.overbooked) 'Overbooked',
                if (b.note != null) b.note!,
                b.status.label,
              ].join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
          ]),
        ),
        if (open) TextButton(onPressed: () => _arrived(context), child: const Text('Arrived')),
        if (b.status == BookingStatus.booked)
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) => v == 'move' ? _move(context) : _cancel(context),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'move', child: Text('Reschedule')),
              PopupMenuItem(value: 'cancel', child: Text('Cancel')),
            ],
          ),
      ]),
    );
  }
}

class _ArrivedDialog extends StatefulWidget {
  const _ArrivedDialog({required this.booking});
  final Booking booking;

  @override
  State<_ArrivedDialog> createState() => _ArrivedDialogState();
}

class _ArrivedDialogState extends State<_ArrivedDialog> {
  final _odo = TextEditingController();
  FuelLevel _fuel = FuelLevel.half;

  Future<void> _save({bool confirm = false}) async {
    final api = SessionScope.of(context).api;
    final odo = int.tryParse(_odo.text.replaceAll(',', '').trim());
    if (odo == null) return;
    try {
      final id = await api.markArrived(widget.booking.id, odometer: odo, fuel: _fuel, confirmOdometer: confirm);
      if (mounted) Navigator.pop(context, id);
    } on AppError catch (e) {
      if (!mounted) return;
      if (e.code == AppErrorCode.odometerLower) {
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text(e.message),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Fix it')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm and save')),
            ],
          ),
        );
        if (yes == true) await _save(confirm: true);
      } else {
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('${widget.booking.plate} arrived'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _odo, autofocus: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Odometer (km)')),
            const SizedBox(height: 12),
            SegmentedButton<FuelLevel>(
              segments: [for (final f in FuelLevel.values) ButtonSegment(value: f, label: Text(f.label))],
              selected: {_fuel},
              onSelectionChanged: (v) => setState(() => _fuel = v.first),
            ),
            const SizedBox(height: 8),
            const Text('A job card opens with the booked service as the complaint.', style: TextStyle(fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Open job card')),
        ],
      );
}

/// Right column: day summary, no-shows of the last 7 days, and settings conflicts.
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.data, required this.onChanged});
  final _DayData data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final booked = data.bookings.where((b) => b.status == BookingStatus.booked).length;
    final arrived = data.bookings.where((b) => b.status == BookingStatus.arrived).length;
    final cap = data.slots.fold<int>(0, (s, x) => s + x.capacity);
    final noShows = data.recent.where((b) => b.status == BookingStatus.noShow).toList().reversed.toList();
    Widget card(String title, Widget child) => Card(
          margin: const EdgeInsets.fromLTRB(0, 0, 16, 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              child,
            ]),
          ),
        );
    return ListView(children: [
      card(
        'This day',
        Wrap(spacing: 20, runSpacing: 8, children: [
          _Stat('Booked', '$booked'),
          _Stat('Arrived', '$arrived'),
          _Stat('Free bays', '${(cap - booked - arrived).clamp(0, cap)}'),
          _Stat('Bays', '${data.settings.bays} × ${data.settings.slotMinutes} min'),
        ]),
      ),
      card(
        'No-shows (last 7 days)',
        noShows.isEmpty
            ? const Text('None')
            : Column(children: [
                for (final b in noShows)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${b.plate} · ${b.customerName ?? ''}'),
                    subtitle: Text(formatSlot(b.slotStart)),
                    trailing: b.mobile == null ? null : Text(formatPkMobile(b.mobile!)),
                  ),
                Text('After ${data.settings.noShowLimit} no-shows app booking is blocked. Unblock from the customer\'s page.',
                    style: const TextStyle(fontSize: 12)),
              ]),
      ),
      if (data.conflicts.isNotEmpty)
        card(
          'Bookings that no longer fit',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final c in data.conflicts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('${formatSlot(DateTime.parse(c['slot_start'] as String))} — ${c['reason']}'),
              ),
            const Text('They were kept. Reschedule or call the customer.', style: TextStyle(fontSize: 12)),
          ]),
        ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]);
}

/// New booking (phone / walk-in) or reschedule an existing one.
class BookingDialog extends StatefulWidget {
  const BookingDialog({super.key, required this.initialDay, this.initialSlot, this.existing});
  final DateTime initialDay;
  final DateTime? initialSlot;
  final Booking? existing;

  @override
  State<BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<BookingDialog> {
  final _search = TextEditingController();
  final _note = TextEditingController();
  List<CustomerHit> _hits = const [];
  CustomerHit? _who;
  List<Service> _services = const [];
  String? _serviceId;
  late DateTime _day = widget.initialSlot == null ? widget.initialDay : DateTime(toPkt(widget.initialSlot!).year, toPkt(widget.initialSlot!).month, toPkt(widget.initialSlot!).day);
  List<Slot> _slots = const [];
  DateTime? _slot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _slot ??= widget.initialSlot;
    final s = SessionScope.of(context);
    if (widget.existing == null && _services.isEmpty) {
      s.api.services(s.current!.stationId).then((l) {
        if (mounted) setState(() => _services = l.where((x) => x.active).toList());
      }).catchError((_) {});
    }
    _loadSlots();
  }

  void _loadSlots() {
    final s = SessionScope.of(context);
    s.api.slots(s.current!.stationId, _day).then((l) {
      if (mounted) setState(() => _slots = l);
    }).catchError((_) {});
  }

  Future<void> _find(String q) async {
    final s = SessionScope.of(context);
    if (q.trim().length < 2) return setState(() => _hits = const []);
    final hits = await s.api.searchCustomers(s.current!.stationId, q);
    if (mounted) setState(() => _hits = hits.where((h) => h.vehicleId != null).toList());
  }

  Future<void> _save({bool overbook = false}) async {
    final s = SessionScope.of(context);
    if (_slot == null || (widget.existing == null && _who == null)) return;
    try {
      if (widget.existing != null) {
        await s.api.rescheduleBooking(widget.existing!.id, _slot!, overbook: overbook);
      } else {
        await s.api.createBooking(s.current!.stationId,
            customerId: _who!.customerId, vehicleId: _who!.vehicleId!, serviceId: _serviceId, slot: _slot!, note: _note.text, overbook: overbook);
      }
      if (mounted) Navigator.pop(context, true);
    } on AppError catch (e) {
      if (!mounted) return;
      if (e.code == AppErrorCode.slotFull) {
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: const Text('This slot is full. Book anyway (overbook)?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Overbook')),
            ],
          ),
        );
        if (yes == true) await _save(overbook: true);
      } else {
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final moving = widget.existing != null;
    return AlertDialog(
      title: Text(moving ? 'Reschedule ${widget.existing!.plate}' : 'New booking'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!moving) ...[
              if (_who == null) ...[
                TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Customer phone, plate or name'),
                  onChanged: _find,
                ),
                for (final h in _hits.take(6))
                  ListTile(
                    dense: true,
                    title: Text('${h.plate} · ${h.name}'),
                    subtitle: Text(formatPkMobile(h.mobile)),
                    onTap: () => setState(() => _who = h),
                  ),
                if (_search.text.trim().length >= 2 && _hits.isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 8), child: Text('No customer with a vehicle found — add them on the Customers page first.')),
              ] else
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.directions_car_outlined),
                  title: Text('${_who!.plate} · ${_who!.name}'),
                  subtitle: Text(formatPkMobile(_who!.mobile)),
                  trailing: TextButton(onPressed: () => setState(() => _who = null), child: const Text('Change')),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _serviceId,
                decoration: const InputDecoration(labelText: 'Service (optional)'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('—')),
                  for (final sv in _services) DropdownMenuItem<String?>(value: sv.id, child: Text(sv.name)),
                ],
                onChanged: (v) => setState(() => _serviceId = v),
              ),
              const SizedBox(height: 12),
            ],
            OutlinedButton.icon(
              icon: const Icon(Icons.event_outlined),
              label: Text('${weekdayNames[_day.weekday - 1]} ${formatDate(_day)}'),
              onPressed: () async {
                final p = await showDatePicker(context: context, initialDate: _day, firstDate: _pkToday(), lastDate: DateTime.now().add(const Duration(days: 365)));
                if (p != null) {
                  setState(() {
                    _day = p;
                    _slot = null;
                  });
                  _loadSlots();
                }
              },
            ),
            const SizedBox(height: 12),
            if (_slots.isEmpty)
              const Text('No slots on this day')
            else
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final sl in _slots)
                  ChoiceChip(
                    label: Text('${formatHm(toPkt(sl.start).hour * 60 + toPkt(sl.start).minute)}  ${sl.free}/${sl.capacity}'),
                    selected: _slot == sl.start,
                    onSelected: (_) => setState(() => _slot = sl.start),
                  ),
              ]),
            if (!moving) ...[
              const SizedBox(height: 12),
              TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _slot == null || (!moving && _who == null) ? null : _save, child: Text(moving ? 'Move' : 'Book')),
      ],
    );
  }
}

/// REQ-014 — bays, slot length, hours per weekday, off-days, no-show limit, bookable services.
class BookingSettingsDialog extends StatefulWidget {
  const BookingSettingsDialog({super.key, required this.initial});
  final BookingSettings initial;

  @override
  State<BookingSettingsDialog> createState() => _BookingSettingsDialogState();
}

class _BookingSettingsDialogState extends State<BookingSettingsDialog> {
  late final _bays = TextEditingController(text: '${widget.initial.bays}');
  late int _slot = widget.initial.slotMinutes;
  late final _limit = TextEditingController(text: '${widget.initial.noShowLimit}');
  late final _ahead = TextEditingController(text: '${widget.initial.daysAhead}');
  late final Map<int, (int, int)?> _hours = {
    for (var d = 1; d <= 7; d++)
      d: () {
        final h = widget.initial.hours.where((x) => x.weekday == d).firstOrNull;
        if (h != null) return (h.opensMin, h.closesMin);
        return widget.initial.isSetUp || d == 7 ? null : (540, 1080);
      }(),
  };
  late final List<DateTime> _off = [...widget.initial.offDays];
  List<Service> _services = const [];
  final Map<String, bool> _bookable = {};

  static final _times = [for (var m = 360; m <= 1380; m += 30) m];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = SessionScope.of(context);
    if (_services.isEmpty) {
      s.api.client.from('services').select('id, name, bookable, active').eq('station_id', s.current!.stationId).order('name', ascending: true).then((rows) {
        if (!mounted) return;
        setState(() {
          _services = [
            for (final r in rows)
              if (r['active'] == true) Service(id: r['id'] as String, name: r['name'] as String, rate: Money.zero, warrantyDays: 0, active: true)
          ];
          for (final r in rows) {
            _bookable[r['id'] as String] = r['bookable'] as bool;
          }
        });
      }).catchError((_) {});
    }
  }

  Widget _timeBox(int value, void Function(int) onChanged) => DropdownButton<int>(
        value: value,
        isDense: true,
        items: [for (final t in _times) DropdownMenuItem(value: t, child: Text(formatHm(t)))],
        onChanged: (v) => onChanged(v!),
      );

  Future<void> _save() async {
    final s = SessionScope.of(context);
    final settings = BookingSettings(
      bays: int.tryParse(_bays.text.trim()) ?? 0,
      slotMinutes: _slot,
      noShowLimit: int.tryParse(_limit.text.trim()) ?? 0,
      daysAhead: int.tryParse(_ahead.text.trim()) ?? 0,
      hours: [
        for (final e in _hours.entries)
          if (e.value != null) DayHours(e.key, e.value!.$1, e.value!.$2)
      ],
      offDays: _off,
    );
    var conflicts = 0;
    final ok = await runAction(context, () async {
      conflicts = await s.api.saveBookingSettings(s.current!.stationId, settings);
      for (final sv in _services) {
        final was = _bookable[sv.id] ?? false;
        await s.api.setServiceBookable(sv.id, was);
      }
    }, success: 'Booking settings saved');
    if (!ok || !mounted) return;
    if (conflicts > 0) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text('$conflicts future booking(s) no longer fit. They were kept and are listed on the Bookings page.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Booking settings'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: TextField(controller: _bays, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Bays (1–50)'))),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _slot,
                    decoration: const InputDecoration(labelText: 'Slot length'),
                    items: [for (final m in slotLengths) DropdownMenuItem(value: m, child: Text('$m min'))],
                    onChanged: (v) => setState(() => _slot = v!),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: TextField(controller: _limit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'No-show limit'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: _ahead, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Book up to (days ahead)'))),
              ]),
              const SizedBox(height: 16),
              const Text('Working hours', style: TextStyle(fontWeight: FontWeight.w700)),
              for (var d = 1; d <= 7; d++)
                Row(children: [
                  SizedBox(
                    width: 150,
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(weekdayNames[d - 1]),
                      value: _hours[d] != null,
                      onChanged: (v) => setState(() => _hours[d] = v == true ? (540, 1080) : null),
                    ),
                  ),
                  if (_hours[d] != null) ...[
                    _timeBox(_hours[d]!.$1, (v) => setState(() => _hours[d] = (v, _hours[d]!.$2))),
                    const Text('  to  '),
                    _timeBox(_hours[d]!.$2, (v) => setState(() => _hours[d] = (_hours[d]!.$1, v))),
                  ] else
                    const Text('Closed'),
                ]),
              const SizedBox(height: 12),
              Row(children: [
                const Expanded(child: Text('Off-days and holidays', style: TextStyle(fontWeight: FontWeight.w700))),
                TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add day'),
                  onPressed: () async {
                    final p = await showDatePicker(context: context, initialDate: _pkToday(), firstDate: _pkToday(), lastDate: DateTime.now().add(const Duration(days: 365)));
                    if (p != null && !_off.contains(p)) setState(() => _off.add(p));
                  },
                ),
              ]),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final d in _off..sort()) InputChip(label: Text(formatDate(d)), onDeleted: () => setState(() => _off.remove(d))),
                if (_off.isEmpty) const Text('None'),
              ]),
              const SizedBox(height: 12),
              const Text('Services customers can book', style: TextStyle(fontWeight: FontWeight.w700)),
              if (_services.isEmpty) const Text('Add services on the Settings page first.'),
              for (final sv in _services)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(sv.name),
                  value: _bookable[sv.id] ?? false,
                  onChanged: (v) => setState(() => _bookable[sv.id] = v == true),
                ),
              const SizedBox(height: 8),
              const Text('Changing settings never cancels existing bookings.', style: TextStyle(fontSize: 12)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}
