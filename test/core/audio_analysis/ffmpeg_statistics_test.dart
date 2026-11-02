import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_analysis/ffmpeg_statistics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  late List<String> calls;

  void mock(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call.method);
      return handler(call);
    });
  }

  setUp(() {
    calls = [];
    resetFfmpegStatisticsForTest();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('calls the native disableStatistics only once across several calls (AN-01)', () async {
    mock((call) async => null);

    await ensureFfmpegStatisticsDisabled();
    await ensureFfmpegStatisticsDisabled();

    expect(calls.where((m) => m == 'disableStatistics'), hasLength(1));
  });

  test('swallows a PlatformException', () async {
    mock((call) async => throw PlatformException(code: 'boom'));
    await expectLater(ensureFfmpegStatisticsDisabled(), completes);
  });

  test('swallows a MissingPluginException', () async {
    mock((call) async => throw MissingPluginException());
    await expectLater(ensureFfmpegStatisticsDisabled(), completes);
  });
}
