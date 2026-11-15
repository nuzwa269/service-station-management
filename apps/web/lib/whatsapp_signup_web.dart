import 'dart:js_interop';

/// What Meta's sign-up window returns: one-time code, WhatsApp Business account and phone number.
typedef WhatsAppSignupResult = ({String code, String wabaId, String phoneNumberId});

@JS('startWhatsAppSignup')
external JSPromise<_Result?> _startSignup(JSString appId, JSString configId);

extension type _Result(JSObject _) implements JSObject {
  external JSString? get code;
  @JS('waba_id')
  external JSString? get wabaId;
  @JS('phone_number_id')
  external JSString? get phoneNumberId;
}

/// Opens Meta's window (helper in web/index.html). Null when the owner closes it.
Future<WhatsAppSignupResult?> startWhatsAppSignup(String appId, String configId) async {
  final r = await _startSignup(appId.toJS, configId.toJS).toDart;
  final code = r?.code?.toDart;
  final waba = r?.wabaId?.toDart;
  final phone = r?.phoneNumberId?.toDart;
  if (code == null || waba == null || phone == null) return null;
  return (code: code, wabaId: waba, phoneNumberId: phone);
}
