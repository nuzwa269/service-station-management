/// Saves bytes as a file in the browser. A stub is used in VM tests.
library;

export 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart';
