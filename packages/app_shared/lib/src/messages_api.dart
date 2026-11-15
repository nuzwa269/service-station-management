import 'package:station_core/station_core.dart';

import 'api.dart';

/// One customer message (REQ-055): automatic WhatsApp / push, or an item in the staff
/// "Messages to send" list (REQ-062).
class OutboxMessage {
  const OutboxMessage({
    required this.id,
    required this.event,
    required this.channel,
    required this.status,
    required this.title,
    required this.body,
    required this.createdAt,
    this.toMobile,
    this.customerName,
    this.manualReason,
    this.refId,
  });

  factory OutboxMessage.fromRow(Map<String, dynamic> r) => OutboxMessage(
        id: r['id'] as int,
        event: r['event'] as String,
        channel: r['channel'] as String,
        status: MessageStatus.parse(r['status'] as String),
        title: r['title'] as String,
        body: r['body'] as String,
        createdAt: DateTime.parse(r['created_at'] as String),
        toMobile: r['to_mobile'] as String?,
        customerName: (r['customer'] as Map<String, dynamic>?)?['name'] as String?,
        manualReason: r['manual_reason'] as String?,
        refId: r['ref_id'] as String?,
      );

  final int id;
  final String event;
  final String channel;
  final MessageStatus status;
  final String title;
  final String body;
  final DateTime createdAt;
  final String? toMobile;
  final String? customerName;
  final String? manualReason;
  final String? refId;

  /// wa.me link, or null when the customer has no valid WhatsApp number.
  String? get whatsAppUrl => toMobile == null ? null : whatsAppLink(toMobile!, body);
}

class WhatsAppAccount {
  const WhatsAppAccount({required this.status, this.reason, this.displayPhone, this.approvedTemplates = 0, this.totalTemplates = 0});

  static const none = WhatsAppAccount(status: WhatsAppStatus.notConnected);

  final WhatsAppStatus status;
  final String? reason;
  final String? displayPhone;
  final int approvedTemplates;
  final int totalTemplates;
}

class MessageEventSetting {
  const MessageEventSetting({required this.code, required this.label, required this.enabled});
  final String code;
  final String label;
  final bool enabled;
}

/// In-app notification for staff (REQ-056), also pushed to their phones.
class StaffNotification {
  const StaffNotification({required this.id, required this.kind, required this.title, required this.createdAt, this.body, this.refId, this.read = false});

  factory StaffNotification.fromRow(Map<String, dynamic> r) => StaffNotification(
        id: r['id'] as int,
        kind: r['kind'] as String,
        title: r['title'] as String,
        body: r['body'] as String?,
        refId: r['ref_id'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
        read: r['read_at'] != null,
      );

  final int id;
  final String kind;
  final String title;
  final String? body;
  final String? refId;
  final DateTime createdAt;
  final bool read;
}

const _outboxColumns = 'id, event, channel, status, title, body, created_at, to_mobile, manual_reason, ref_id, customer:customers(name)';

extension MessagesApi on StationApi {
  /// REQ-062: WhatsApp messages staff still have to send (newest first).
  Future<List<OutboxMessage>> messagesToSend(String stationId) => guard(() async => [
        for (final r in await client
            .from('message_outbox')
            .select(_outboxColumns)
            .eq('station_id', stationId)
            .eq('channel', 'whatsapp')
            .inFilter('status', ['manual', 'opened'])
            .order('created_at', ascending: false)
            .limit(200))
          OutboxMessage.fromRow(r)
      ]);

  /// Recent WhatsApp messages of every status (sent automatically, sent by staff, skipped).
  Future<List<OutboxMessage>> recentMessages(String stationId, {int limit = 100}) => guard(() async => [
        for (final r in await client
            .from('message_outbox')
            .select(_outboxColumns)
            .eq('station_id', stationId)
            .eq('channel', 'whatsapp')
            .order('created_at', ascending: false)
            .limit(limit))
          OutboxMessage.fromRow(r)
      ]);

  /// Messages about one record (job card and its invoice).
  Future<List<OutboxMessage>> messagesFor(List<String> refIds) => guard(() async => [
        for (final r in await client
            .from('message_outbox')
            .select(_outboxColumns)
            .eq('channel', 'whatsapp')
            .inFilter('ref_id', refIds)
            .order('created_at', ascending: false))
          OutboxMessage.fromRow(r)
      ]);

  /// Messages about a job card and its invoice.
  Future<List<OutboxMessage>> messagesForJob(String jobId) => guard(() async {
        final inv = await client.from('invoices').select('id').eq('job_id', jobId);
        return messagesFor([jobId, for (final i in inv) i['id'] as String]);
      });

  /// [action]: opened, sent or skipped.
  Future<void> markMessage(int id, String action) =>
      guard(() async => await client.rpc('message_mark', params: {'p_message': id, 'p_action': action}));

  Future<WhatsAppAccount> whatsAppAccount(String stationId) => guard(() async {
        final a = await client.from('whatsapp_accounts').select().eq('station_id', stationId).maybeSingle();
        if (a == null) return WhatsAppAccount.none;
        final t = await client.from('whatsapp_templates').select('status').eq('station_id', stationId);
        return WhatsAppAccount(
          status: WhatsAppStatus.parse(a['status'] as String?),
          reason: a['status_reason'] as String?,
          displayPhone: a['display_phone'] as String?,
          approvedTemplates: t.where((x) => x['status'] == 'approved').length,
          totalTemplates: t.length,
        );
      });

  Future<List<MessageEventSetting>> messageEvents(String stationId) => guard(() async {
        final events = await client.from('message_events').select('code, label, sort').order('sort', ascending: true);
        final settings = await client.from('message_event_settings').select('event, enabled').eq('station_id', stationId);
        final off = {for (final s in settings) s['event'] as String: s['enabled'] as bool};
        return [
          for (final e in events)
            MessageEventSetting(code: e['code'] as String, label: e['label'] as String, enabled: off[e['code']] ?? true)
        ];
      });

  Future<void> setMessageEvents(String stationId, Map<String, bool> events) =>
      guard(() async => await client.rpc('station_set_message_events', params: {'p_station': stationId, 'p_events': events}));

  Future<void> disconnectWhatsApp(String stationId) =>
      guard(() async => await client.rpc('station_whatsapp_disconnect', params: {'p_station': stationId}));

  /// Finishes Meta Embedded Signup with what Meta's window returned.
  Future<void> connectWhatsApp(String stationId, {required String code, required String wabaId, required String phoneNumberId}) =>
      guard(() async => await client.functions.invoke('whatsapp-connect', body: {
            'station_id': stationId,
            'code': code,
            'waba_id': wabaId,
            'phone_number_id': phoneNumberId,
          }));

  Future<List<StaffNotification>> notifications(String stationId, {int limit = 50}) => guard(() async => [
        for (final r in await client
            .from('notifications')
            .select('id, kind, title, body, ref_id, created_at, read_at')
            .eq('station_id', stationId)
            .order('created_at', ascending: false)
            .limit(limit))
          StaffNotification.fromRow(r)
      ]);

  Future<void> markStaffNotificationsRead(String stationId) =>
      guard(() async => await client.rpc('notifications_mark_read', params: {'p_station': stationId}));

  /// Push: the phone's FCM token after login; removed on sign-out.
  Future<void> registerDevice(String token, {required String app}) =>
      guard(() async => await client.rpc('register_device', params: {'p_token': token, 'p_app': app}));

  Future<void> unregisterDevice(String token) => guard(() async => await client.rpc('unregister_device', params: {'p_token': token}));
}
