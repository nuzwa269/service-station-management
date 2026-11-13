import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

void downloadBytes(Uint8List bytes, String fileName) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'));
  final url = web.URL.createObjectURL(blob);
  (web.document.createElement('a') as web.HTMLAnchorElement)
    ..href = url
    ..download = fileName
    ..click();
  web.URL.revokeObjectURL(url);
}
