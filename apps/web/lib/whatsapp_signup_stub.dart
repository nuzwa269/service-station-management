/// What Meta's sign-up window returns: one-time code, WhatsApp Business account and phone number.
typedef WhatsAppSignupResult = ({String code, String wabaId, String phoneNumberId});

/// Not available outside the browser.
Future<WhatsAppSignupResult?> startWhatsAppSignup(String appId, String configId) async => null;
