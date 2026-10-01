import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/system/focus_keep_screen_on.dart';

class _FakePlatform implements KeepScreenOnPlatform {
  bool powerSave = false;
  final List<bool> calls = [];
  final StreamController<bool> powerSaveChanges = StreamController<bool>.broadcast();

  @override
  Future<bool> isPowerSaveMode() async => powerSave;

  @override
  Future<void> setKeepScreenOn(bool enabled) async => calls.add(enabled);

  @override
  Stream<bool> get powerSaveModeChanges => powerSaveChanges.stream;

  Future<void> switchPowerSave(bool enabled) async {
    powerSave = enabled;
    powerSaveChanges.add(enabled);
    // Laisse le contrôleur traiter l'événement (réévaluation asynchrone).
    await pumpEventQueue();
  }
}

void main() {
  late _FakePlatform platform;
  late FocusKeepScreenOnController controller;

  setUp(() {
    platform = _FakePlatform();
    controller = FocusKeepScreenOnController(platform);
  });

  tearDown(() {
    controller.dispose();
    platform.powerSaveChanges.close();
  });

  test('keeps the screen on while Focus is active and power saving is off', () async {
    await controller.setFocusActive(true);

    expect(controller.isKeepingScreenOn, isTrue);
    expect(platform.calls, [true]);
  });

  test('never keeps the screen on in power saving mode, even in Focus', () async {
    platform.powerSave = true;

    await controller.setFocusActive(true);

    expect(controller.isKeepingScreenOn, isFalse);
    expect(platform.calls, isEmpty);
  });

  test('releases the screen as soon as Focus ends', () async {
    await controller.setFocusActive(true);
    await controller.setFocusActive(false);

    expect(controller.isKeepingScreenOn, isFalse);
    expect(platform.calls, [true, false]);
  });

  test('follows power saving switching on then off during Focus', () async {
    await controller.setFocusActive(true);

    await platform.switchPowerSave(true);
    expect(controller.isKeepingScreenOn, isFalse);

    await platform.switchPowerSave(false);
    expect(controller.isKeepingScreenOn, isTrue);
    expect(platform.calls, [true, false, true]);
  });

  test('ignores power saving changes outside Focus and never touches the platform before it', () async {
    await controller.setFocusActive(false);
    await platform.switchPowerSave(true);
    await platform.switchPowerSave(false);

    expect(platform.calls, isEmpty);
  });
}
