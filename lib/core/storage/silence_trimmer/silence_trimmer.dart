import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

class TrimResult {
  const TrimResult({required this.trimStartMs, required this.trimEndMs});

  final int trimStartMs;
  final int trimEndMs;
}

/// Détecte le silence en tête/fin de piste (dB < seuil pendant > durée min) via
/// le filtre `silencedetect` de FFmpeg, pour peupler `trim_start_ms`/`trim_end_ms`.
///
/// Convention : `trim_start_ms` = durée de silence à ignorer depuis le début
/// (la lecture doit démarrer à cet offset) ; `trim_end_ms` = durée de silence à
/// ignorer avant la fin (la lecture doit s'arrêter à `duration_ms - trim_end_ms`).
class SilenceTrimmerService {
  static const double silenceThresholdDb = -45.0;
  static const Duration minSilenceDuration = Duration(milliseconds: 500);

  Future<TrimResult> detect(String filePath, {required int durationMs}) async {
    final List<_SilenceWindow> windows = await _runSilenceDetect(filePath);
    if (windows.isEmpty) {
      return const TrimResult(trimStartMs: 0, trimEndMs: 0);
    }

    int trimStartMs = 0;
    final _SilenceWindow first = windows.first;
    if (first.startMs <= 50 && first.durationMs >= minSilenceDuration.inMilliseconds) {
      trimStartMs = first.endMs;
    }

    int trimEndMs = 0;
    final _SilenceWindow last = windows.last;
    if (durationMs - last.endMs <= 50 && last.durationMs >= minSilenceDuration.inMilliseconds) {
      trimEndMs = durationMs - last.startMs;
    }

    return TrimResult(trimStartMs: trimStartMs, trimEndMs: trimEndMs);
  }

  Future<List<_SilenceWindow>> _runSilenceDetect(String filePath) async {
    final double thresholdSec = minSilenceDuration.inMilliseconds / 1000;
    final String command = '-i "$filePath" -af silencedetect=noise=${silenceThresholdDb}dB:d=$thresholdSec -f null -';

    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    if (returnCode == null || !ReturnCode.isSuccess(returnCode)) {
      return const [];
    }

    final String logs = await session.getAllLogsAsString() ?? '';
    return _parseSilenceLog(logs);
  }

  List<_SilenceWindow> _parseSilenceLog(String logs) {
    final RegExp startPattern = RegExp(r'silence_start:\s*([\d.]+)');
    final RegExp endPattern = RegExp(r'silence_end:\s*([\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)');

    final List<double> starts = startPattern.allMatches(logs).map((m) => double.parse(m.group(1)!)).toList();

    final List<_SilenceWindow> windows = [];
    int i = 0;
    for (final match in endPattern.allMatches(logs)) {
      final double endSec = double.parse(match.group(1)!);
      final double durationSec = double.parse(match.group(2)!);
      final double startSec = i < starts.length ? starts[i] : endSec - durationSec;
      windows.add(
        _SilenceWindow(
          startMs: (startSec * 1000).round(),
          endMs: (endSec * 1000).round(),
          durationMs: (durationSec * 1000).round(),
        ),
      );
      i++;
    }
    return windows;
  }
}

class _SilenceWindow {
  const _SilenceWindow({required this.startMs, required this.endMs, required this.durationMs});

  final int startMs;
  final int endMs;
  final int durationMs;
}
