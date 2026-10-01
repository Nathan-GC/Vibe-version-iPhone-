import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/platform/app_platform.dart';
import 'package:vibe_power/vibe_power.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('tests run the Android path by default (existing suite unchanged)', () {
    expect(AppPlatform.isAndroid, isTrue);
    expect(AppPlatform.isIOS, isFalse);
  });

  test('iOS branches can be exercised through debugDefaultTargetPlatformOverride', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    expect(AppPlatform.isIOS, isTrue);
    expect(AppPlatform.isAndroid, isFalse);
  });

  group('VibePower outside Android/iOS (development host)', () {
    test('system calls are guarded: no MissingPluginException', () async {
      await expectLater(VibePower.setKeepScreenOn(true), completes);
      expect(await VibePower.isPowerSaveMode(), isFalse);
      expect(await VibePower.powerSaveModeChanges.isEmpty, isTrue);
    });
  });
}
