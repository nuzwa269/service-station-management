/// REQ-055, REQ-061, REQ-062 — customer message helpers shared by the web dashboard and the Staff app.
library;

/// wa.me link that opens WhatsApp (app on the phone, WhatsApp Web on a computer) with the
/// customer's number and the text ready. [mobile] is 03XXXXXXXXX.
String whatsAppLink(String mobile, String text) {
  final digits = mobile.replaceAll(RegExp(r'[^0-9]'), '');
  final intl = digits.startsWith('92') ? digits : '92${digits.replaceFirst(RegExp(r'^0'), '')}';
  return 'https://wa.me/$intl?text=${Uri.encodeComponent(text)}';
}

/// Status of the station's own WhatsApp Business account.
enum WhatsAppStatus {
  notConnected('not_connected', 'Not connected'),
  pending('pending', 'Pending'),
  connected('connected', 'Connected'),
  paymentProblem('payment_problem', 'Payment problem'),
  disconnected('disconnected', 'Disconnected');

  const WhatsAppStatus(this.code, this.label);
  final String code;
  final String label;

  static WhatsAppStatus parse(String? code) =>
      values.firstWhere((s) => s.code == code, orElse: () => WhatsAppStatus.notConnected);

  /// Events go out automatically only when connected.
  bool get sendsAutomatically => this == WhatsAppStatus.connected;
}

/// Outbox row status (automatic: queued → sending → sent; manual: manual → opened → sent / skipped).
enum MessageStatus {
  queued('queued', 'Waiting to send'),
  sending('sending', 'Sending'),
  sent('sent', 'Sent'),
  failed('failed', 'Failed'),
  manual('manual', 'To send'),
  opened('opened', 'Opened in WhatsApp'),
  skipped('skipped', 'Skipped');

  const MessageStatus(this.code, this.label);
  final String code;
  final String label;

  static MessageStatus parse(String code) => values.firstWhere((s) => s.code == code, orElse: () => MessageStatus.manual);

  /// Still in the staff "Messages to send" list.
  bool get needsStaff => this == MessageStatus.manual || this == MessageStatus.opened;
}
