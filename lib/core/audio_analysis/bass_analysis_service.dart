import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path_provider/path_provider.dart';

import 'bass_analysis.dart';

/// Lance une commande FFmpeg et dit si elle a réussi. Injectable pour tester le
/// service sans FFmpeg (indisponible hors device).
typedef FfmpegRunner = Future<bool> Function(String command);

Future<bool> _runWithFfmpegKit(String command) async {
  final session = await FFmpegKit.execute(command);
  final returnCode = await session.getReturnCode();
  return returnCode != null && ReturnCode.isSuccess(returnCode);
}

/// Analyse hors ligne d'un morceau : enveloppe des basses (25 Hz) et BPM
/// estimé, pour la réactivité de la Vibe "Behind the window". Rien ne sort de
/// l'appareil et le micro n'est pas sollicité : FFmpeg relit le fichier local.
class BassAnalysisService {
  BassAnalysisService({FfmpegRunner? runFfmpeg, Future<Directory> Function()? temporaryDirectory})
      : _runFfmpeg = runFfmpeg ?? _runWithFfmpegKit,
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final FfmpegRunner _runFfmpeg;
  final Future<Directory> Function() _temporaryDirectory;

  /// Null (sans exception) si le fichier est absent, si FFmpeg échoue ou ne
  /// produit rien : l'effet retombe alors sur la pulsation du tempo.
  Future<({Uint8List envelope, int? estimatedBpm})?> analyze(String filePath) async {
    if (!await File(filePath).exists()) return null;

    File? output;
    try {
      final Directory directory = await _temporaryDirectory();
      output = File('${directory.path}/bass_analysis_${DateTime.now().microsecondsSinceEpoch}.txt');
      // Mono, 8 kHz, passe-bas 150 Hz : seules les basses comptent et le
      // calcul reste léger. Fenêtres de 80 échantillons = 10 ms (100 Hz).
      // `ametadata` écrit dans un fichier plutôt que dans les logs : ~24 000
      // lignes pour 4 minutes passeraient une à une par le canal natif.
      final String command = '-hide_banner -nostats -i "$filePath" -vn -ac 1 '
          '-af "aresample=8000,lowpass=f=150,asetnsamples=n=80:p=0,astats=metadata=1:reset=1,'
          'ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=${output.path}" -f null -';
      if (!await _runFfmpeg(command)) return null;
      if (!await output.exists()) return null;

      final List<double> levels = parseRmsLevelsDb(await output.readAsString());
      if (levels.isEmpty) return null;
      return (envelope: bassEnvelopeFromDb(levels), estimatedBpm: estimateBpm(levels));
    } catch (_) {
      // Le canal natif FFmpeg ou le disque peuvent échouer de façons variées :
      // l'analyse est facultative, jamais une raison de planter le lecteur.
      return null;
    } finally {
      try {
        if (output != null && await output.exists()) await output.delete();
      } catch (_) {
        // Fichier temporaire : l'OS nettoiera le dossier cache.
      }
    }
  }
}
