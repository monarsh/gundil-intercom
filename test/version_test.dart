import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';

void main() {
  test('the version shown in the app matches pubspec.yaml', () {
    String versionOf(String path) => RegExp(
      r'^version:\s*([0-9.]+)',
      multiLine: true,
    ).firstMatch(File(path).readAsStringSync())!.group(1)!;
    expect(appVersion, versionOf('pubspec.yaml'));
    expect(appVersion, versionOf('packages/intercom_core/pubspec.yaml'));
  });
}
