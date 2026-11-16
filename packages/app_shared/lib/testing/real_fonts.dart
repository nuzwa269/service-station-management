// Test helper: loads Roboto and Material Icons from the Flutter SDK so widget tests measure text
// like a real Android phone (the default test font draws every letter as a wide square).
// Import only from tests: `import 'package:app_shared/testing/real_fonts.dart';`
import 'dart:io';

import 'package:flutter/services.dart';

Future<void> loadRealFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? _guessFlutterRoot();
  final dir = '$flutterRoot/bin/cache/artifacts/material_fonts';
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final file = File('$dir/$f');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Roboto', ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf', 'roboto-black.ttf', 'roboto-light.ttf']);
  await family('MaterialIcons', ['materialicons-regular.otf']);
}

String _guessFlutterRoot() {
  final exe = Platform.resolvedExecutable; // …/bin/cache/dart-sdk/bin/dart(.exe) or flutter_tester
  final i = exe.replaceAll('\\', '/').indexOf('/bin/cache/');
  return i > 0 ? exe.replaceAll('\\', '/').substring(0, i) : '/c/src/flutter';
}
