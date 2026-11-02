import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_analysis/bass_analysis_service.dart';

void main() {
  late Directory dir;
  late File audio;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bass_analysis_service_test');
    audio = File('${dir.path}/song.mp3')..writeAsStringSync('x');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Noms des fichiers restant dans le dossier temporaire (le fichier de sortie doit avoir disparu).
  List<String> remainingFiles() => dir.listSync().map((e) => e.uri.pathSegments.last).toList();

  /// Sortie `ametadata=mode=print` de [levels] (dB), une fenêtre par bloc.
  String metadata(List<String> levels) => [
        for (int i = 0; i < levels.length; i++)
          'frame:$i pts:${i * 80} pts_time:${i * 0.01}\nlavfi.astats.Overall.RMS_level=${levels[i]}\n',
      ].join();

  /// Faux FFmpeg : retrouve le fichier `file=` demandé dans la commande et y
  /// écrit [content], comme le ferait `ametadata`.
  FfmpegRunner runnerWriting(String content, {List<String>? commands, bool success = true}) {
    return (String command) async {
      commands?.add(command);
      final String path = RegExp(r'file=([^"]+)"').firstMatch(command)!.group(1)!;
      File(path).writeAsStringSync(content);
      return success;
    };
  }

  BassAnalysisService serviceWith(FfmpegRunner runner) =>
      BassAnalysisService(runFfmpeg: runner, temporaryDirectory: () async => dir);

  test('builds the single-channel 8 kHz low-pass command and returns the envelope and BPM', () async {
    final List<String> commands = [];
    // 40 fenêtres de 10 ms -> 10 octets ; trop court pour un BPM.
    final service = serviceWith(runnerWriting(metadata(List.filled(40, '-20.0')), commands: commands));

    final result = await service.analyze(audio.path);

    expect(result, isNotNull);
    expect(result!.envelope, hasLength(10));
    expect(result.estimatedBpm, isNull);
    expect(commands.single, contains('-i "${audio.path}"'));
    expect(
      commands.single,
      contains('-vn -ac 1 -af "aresample=8000,lowpass=f=150,asetnsamples=n=80:p=0,astats='),
    );
    expect(commands.single, contains(',ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file='));
    expect(commands.single, endsWith('-f null -'));
  });

  test('restricts astats to the overall RMS level (AN-01)', () async {
    final List<String> commands = [];
    await serviceWith(runnerWriting(metadata(['-20']), commands: commands)).analyze(audio.path);

    final String astats = RegExp(r'astats=[^,]+').firstMatch(commands.single)!.group(0)!;
    expect(astats, contains('measure_overall=RMS_level'));
    expect(astats, contains('measure_perchannel=none'));
    expect(astats, contains('metadata=1:reset=1'));
  });

  group('failure logging (AN-02)', () {
    late List<String> logs;

    setUp(() {
      logs = [];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);
    });

    test('logs nothing on success', () async {
      await serviceWith(runnerWriting(metadata(['-20']))).analyze(audio.path);
      expect(logs, isEmpty);
    });

    test('logs a failing launcher with the basename only', () async {
      await serviceWith(runnerWriting(metadata(['-20']), success: false)).analyze(audio.path);
      expect(logs, hasLength(1));
      expect(logs.single, contains('[BassAnalysis]'));
      expect(logs.single, contains('song.mp3'));
      expect(logs.single, isNot(contains(dir.path)));
    });

    test('logs an exception with its type and message', () async {
      await serviceWith((String command) async => throw StateError('native channel down')).analyze(audio.path);
      expect(logs, hasLength(1));
      expect(logs.single, contains('[BassAnalysis]'));
      expect(logs.single, contains('StateError'));
      expect(logs.single, contains('native channel down'));
    });

    test('logs an empty output', () async {
      await serviceWith(runnerWriting('')).analyze(audio.path);
      expect(logs, hasLength(1));
      expect(logs.single, contains('[BassAnalysis]'));
    });
  });

  test('removes the temporary output file after a successful analysis', () async {
    final service = serviceWith(runnerWriting(metadata(['-20'])));

    await service.analyze(audio.path);

    expect(remainingFiles(), ['song.mp3']);
  });

  test('returns null when FFmpeg fails, and still removes the temporary file', () async {
    final service = serviceWith(runnerWriting(metadata(['-20']), success: false));

    expect(await service.analyze(audio.path), isNull);
    expect(remainingFiles(), ['song.mp3']);
  });

  test('returns null when the output file is empty or has no level', () async {
    expect(await serviceWith(runnerWriting('')).analyze(audio.path), isNull);
    expect(remainingFiles(), ['song.mp3']);
  });

  test('returns null, without running FFmpeg, when the audio file is missing', () async {
    int calls = 0;
    final service = serviceWith((String command) async {
      calls++;
      return true;
    });

    expect(await service.analyze('${dir.path}/absent.mp3'), isNull);
    expect(calls, 0);
  });

  test('returns null instead of throwing when the launcher throws, and cleans up', () async {
    final service = serviceWith((String command) async {
      final String path = RegExp(r'file=([^"]+)"').firstMatch(command)!.group(1)!;
      File(path).writeAsStringSync('partial');
      throw StateError('native channel down');
    });

    expect(await service.analyze(audio.path), isNull);
    expect(remainingFiles(), ['song.mp3']);
  });
}
