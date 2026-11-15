import 'package:station_core/station_core.dart';

import 'api.dart';

class BookingSettings {
  const BookingSettings({
    required this.bays,
    required this.slotMinutes,
    required this.noShowLimit,
    required this.daysAhead,
    required this.hours,
    required this.offDays,
  });

  static const empty = BookingSettings(bays: 2, slotMinutes: 60, noShowLimit: 3, daysAhead: 30, hours: [], offDays: []);

  final int bays;
  final int slotMinutes;
  final int noShowLimit;
  final int daysAhead;
  final List<DayHours> hours;
  final List<DateTime> offDays;

  bool get isSetUp => hours.isNotEmpty;
}

class Slot {
  const Slot({required this.start, required this.end, required this.capacity, required this.booked});

  factory Slot.fromRow(Map<String, dynamic> r) => Slot(
        start: DateTime.parse(r['slot_start'] as String),
        end: DateTime.parse(r['slot_end'] as String),
        capacity: r['capacity'] as int,
        booked: r['booked'] as int,
      );

  final DateTime start;
  final DateTime end;
  final int capacity;
  final int booked;
  int get free => capacity - booked < 0 ? 0 : capacity - booked;
}

class Booking {
  const Booking({
    required this.id,
    required this.slotStart,
    required this.status,
    required this.plate,
    this.customerId,
    this.customerName,
    this.mobile,
    this.vehicleId,
    this.service,
    this.note,
    this.source,
    this.overbooked = false,
    this.jobId,
  });

  /// Staff row: bookings with customer, vehicle and service joined.
  factory Booking.fromRow(Map<String, dynamic> r) {
    final c = r['customer'] as Map<String, dynamic>? ?? const {};
    final v = r['vehicle'] as Map<String, dynamic>? ?? const {};
    final s = r['service'] as Map<String, dynamic>?;
    return Booking(
      id: r['id'] as String,
      slotStart: DateTime.parse(r['slot_start'] as String),
      status: BookingStatus.parse(r['status'] as String),
      plate: v['plate'] as String? ?? r['plate'] as String? ?? '',
      customerId: r['customer_id'] as String?,
      customerName: c['name'] as String?,
      mobile: c['mobile'] as String?,
      vehicleId: r['vehicle_id'] as String?,
      service: s?['name'] as String? ?? r['service'] as String?,
      note: r['note'] as String?,
      source: r['source'] as String?,
      overbooked: r['overbooked'] as bool? ?? false,
      jobId: r['job_id'] as String?,
    );
  }

  final String id;
  final DateTime slotStart;
  final BookingStatus status;
  final String plate;
  final String? customerId;
  final String? customerName;
  final String? mobile;
  final String? vehicleId;
  final String? service;
  final String? note;
  final String? source;
  final bool overbooked;
  final String? jobId;
}

String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Station staff: settings, calendar, bookings, no-show blocks, next service (REQ-014…017, REQ-049).
extension BookingApi on StationApi {
  Future<BookingSettings> bookingSettings(String stationId) => guard(() async {
        final s = await client.from('booking_settings').select().eq('station_id', stationId).maybeSingle();
        final h = (await client.from('booking_hours').select().eq('station_id', stationId).order('weekday', ascending: true) as List)
            .cast<Map<String, dynamic>>();
        final o = (await client.from('booking_off_days').select('day').eq('station_id', stationId).order('day', ascending: true) as List)
            .cast<Map<String, dynamic>>();
        if (s == null) return BookingSettings.empty;
        return BookingSettings(
          bays: s['bays'] as int,
          slotMinutes: s['slot_minutes'] as int,
          noShowLimit: s['no_show_limit'] as int,
          daysAhead: s['days_ahead'] as int,
          hours: [for (final r in h) DayHours.fromRow(r)],
          offDays: [for (final r in o) DateTime.parse(r['day'] as String)],
        );
      });

  /// Returns how many future bookings no longer fit the new settings (kept, listed for staff).
  Future<int> saveBookingSettings(String stationId, BookingSettings s) => guard(() async =>
      await client.rpc('station_save_booking_settings', params: {
        'p_station': stationId,
        'p_bays': s.bays,
        'p_slot_minutes': s.slotMinutes,
        'p_no_show_limit': s.noShowLimit,
        'p_hours': [for (final h in s.hours) h.toJson()],
        'p_off_days': [for (final d in s.offDays) _day(d)],
        'p_days_ahead': s.daysAhead,
      }) as int);

  Future<List<Map<String, dynamic>>> bookingConflicts(String stationId) => guard(() async =>
      (await client.rpc('station_booking_conflicts', params: {'p_station': stationId}) as List).cast<Map<String, dynamic>>());

  Future<void> setServiceBookable(String serviceId, bool bookable) =>
      guard(() async => await client.rpc('station_set_service_bookable', params: {'p_service': serviceId, 'p_bookable': bookable}));

  Future<List<Slot>> slots(String stationId, DateTime day) => guard(() async =>
      [for (final r in (await client.rpc('booking_slots', params: {'p_station': stationId, 'p_day': _day(day)}) as List)) Slot.fromRow(r as Map<String, dynamic>)]);

  /// Bookings whose slot starts in [from, to) (UTC instants).
  Future<List<Booking>> bookings(String stationId, DateTime from, DateTime to) => guard(() async => [
        for (final r in (await client
            .from('bookings')
            .select('*, customer:customers(name, mobile), vehicle:vehicles(plate), service:services(name)')
            .eq('station_id', stationId)
            .gte('slot_start', from.toUtc().toIso8601String())
            .lt('slot_start', to.toUtc().toIso8601String())
            .order('slot_start', ascending: true) as List))
          Booking.fromRow(r as Map<String, dynamic>)
      ]);

  Future<String> createBooking(String stationId,
          {required String customerId, required String vehicleId, String? serviceId, required DateTime slot, String? note, bool overbook = false}) =>
      guard(() async => await client.rpc('station_create_booking', params: {
            'p_station': stationId,
            'p_customer': customerId,
            'p_vehicle': vehicleId,
            'p_service': serviceId,
            'p_slot': slot.toUtc().toIso8601String(),
            'p_note': note,
            'p_overbook': overbook,
          }) as String);

  Future<void> rescheduleBooking(String bookingId, DateTime slot, {bool overbook = false}) => guard(() async => await client.rpc(
      'station_reschedule_booking', params: {'p_booking': bookingId, 'p_slot': slot.toUtc().toIso8601String(), 'p_overbook': overbook}));

  Future<void> cancelBooking(String bookingId, String reason) =>
      guard(() async => await client.rpc('station_cancel_booking', params: {'p_booking': bookingId, 'p_reason': reason}));

  Future<String> markArrived(String bookingId, {required int odometer, required FuelLevel fuel, String? complaints, bool confirmOdometer = false}) =>
      guard(() async => await client.rpc('station_mark_arrived', params: {
            'p_booking': bookingId,
            'p_odometer': odometer,
            'p_fuel': fuel.code,
            'p_complaints': complaints,
            'p_confirm_odometer': confirmOdometer,
          }) as String);

  Future<({int noShows, bool blocked})> noShowStatus(String customerId) => guard(() async {
        final r = await client.from('no_show_counters').select().eq('customer_id', customerId).maybeSingle();
        return (noShows: r?['no_shows'] as int? ?? 0, blocked: r?['blocked'] as bool? ?? false);
      });

  Future<void> unblockCustomer(String customerId) =>
      guard(() async => await client.rpc('station_unblock_customer', params: {'p_customer': customerId}));

  Future<void> setNextService(String jobId, {DateTime? date, int? km}) => guard(() async => await client.rpc('job_set_next_service',
      params: {'p_job': jobId, 'p_date': date == null ? null : _day(date), 'p_km': km}));

  Future<List<Map<String, dynamic>>> dueForService(String stationId, {int days = 7}) => guard(() async =>
      (await client.rpc('station_due_for_service', params: {'p_station': stationId, 'p_days': days}) as List).cast<Map<String, dynamic>>());
}

// ---- Customer app (REQ-047, REQ-015, REQ-016, REQ-020, REQ-022, REQ-048) -----------------

class LinkedStation {
  const LinkedStation({
    required this.stationId,
    required this.name,
    required this.city,
    required this.code,
    required this.customerName,
    required this.blocked,
    required this.readOnly,
    this.phone,
  });

  factory LinkedStation.fromRow(Map<String, dynamic> r) => LinkedStation(
        stationId: r['station_id'] as String,
        name: r['name'] as String,
        city: r['city'] as String,
        phone: r['phone'] as String?,
        code: r['station_code'] as String,
        customerName: r['customer_name'] as String,
        blocked: r['blocked'] as bool,
        readOnly: r['read_only'] as bool,
      );

  final String stationId;
  final String name;
  final String city;
  final String? phone;
  final String code;
  final String customerName;
  final bool blocked;
  final bool readOnly;
}

extension CustomerApi on StationApi {
  Future<List<LinkedStation>> myStations() => guard(() async =>
      [for (final r in (await client.rpc('customer_stations') as List)) LinkedStation.fromRow(r as Map<String, dynamic>)]);

  Future<void> linkStation(String code, {String? name}) =>
      guard(() async => await client.rpc('customer_link_station', params: {'p_code': code.trim(), 'p_name': name}));

  /// Vehicles, bookable services, bookings, jobs, invoices and dues at one station.
  Future<Map<String, dynamic>> myStationData(String stationId) =>
      guard(() async => (await client.rpc('customer_station_data', params: {'p_station': stationId})) as Map<String, dynamic>);

  Future<String> addMyVehicle(String stationId, {required String plate, String? make, String? model}) => guard(() async =>
      await client.rpc('customer_add_vehicle', params: {'p_station': stationId, 'p_plate': plate, 'p_make': make, 'p_model': model}) as String);

  Future<String> book(String stationId, {required String vehicleId, String? serviceId, required DateTime slot, String? note}) =>
      guard(() async => await client.rpc('customer_book', params: {
            'p_station': stationId,
            'p_vehicle': vehicleId,
            'p_service': serviceId,
            'p_slot': slot.toUtc().toIso8601String(),
            'p_note': note,
          }) as String);

  Future<void> cancelMyBooking(String bookingId) => guard(() async => await client.rpc('customer_cancel_booking', params: {'p_booking': bookingId}));

  Future<void> rescheduleMyBooking(String bookingId, DateTime slot) => guard(() async =>
      await client.rpc('customer_reschedule_booking', params: {'p_booking': bookingId, 'p_slot': slot.toUtc().toIso8601String()}));

  Future<Map<String, dynamic>> myJob(String jobId) =>
      guard(() async => (await client.rpc('customer_job', params: {'p_job': jobId})) as Map<String, dynamic>);

  Future<void> decide(String jobId, {required bool approve, bool extra = false}) =>
      guard(() async => await client.rpc('customer_decide', params: {'p_job': jobId, 'p_approve': approve, 'p_extra': extra}));

  Future<Map<String, dynamic>> myInvoice(String invoiceId) =>
      guard(() async => (await client.rpc('customer_invoice', params: {'p_invoice': invoiceId})) as Map<String, dynamic>);

  Future<List<Map<String, dynamic>>> myVehicleHistory(String vehicleId) => guard(() async =>
      (await client.rpc('customer_vehicle_history', params: {'p_vehicle': vehicleId}) as List).cast<Map<String, dynamic>>());

  Future<List<Map<String, dynamic>>> myNotifications() =>
      guard(() async => (await client.rpc('customer_notifications_list') as List).cast<Map<String, dynamic>>());

  Future<void> markNotificationsRead() => guard(() async => await client.rpc('customer_mark_notifications_read'));
}
