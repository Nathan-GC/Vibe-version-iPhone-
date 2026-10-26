import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';

import '../storage_manager/storage_manager_service.dart';

/// Écrit la pochette intégrée à un fichier audio (flux vidéo `attached_pic`,
/// repéré par [MetadataExtractor]) dans `Music/AppFolder/track_covers/`, au
/// même endroit que les pochettes choisies à la main. Copie de flux : l'image
/// n'est jamais réencodée, donc le scan reste peu coûteux.
class EmbeddedCoverExtractor {
  EmbeddedCoverExtractor({StorageManagerService? storage}) : _storage = storage ?? StorageManagerService();

  final StorageManagerService _storage;

  /// `.png` pour un flux PNG, `.jpg` sinon (le cas courant : MJPEG).
  @visibleForTesting
  static String extensionForCodec(String codec) => codec.toLowerCase() == 'png' ? '.png' : '.jpg';

  /// Chemin de la pochette extraite de [audio] pour le titre [trackId], ou
  /// `null` si l'extraction échoue — jamais d'exception : une pochette
  /// illisible ne doit pas faire échouer le scan du titre.
  ///
  /// Ne supprime pas les autres fichiers du titre dans `track_covers/` : c'est
  /// `TrackRepository` qui décide si cette pochette est appliquée, et une
  /// pochette choisie à la main doit survivre à un rescan.
  Future<String?> extract(File audio, {required String trackId, required String codec}) async {
    String? outputPath;
    try {
      outputPath = await _storage.newOwnedFilePath('track_covers', trackId, extensionForCodec(codec));
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        audio.path,
        '-map',
        '0:v:0',
        '-c:v',
        'copy',
        '-frames:v',
        '1',
        '-update',
        '1',
        outputPath,
      ]);
      final ReturnCode? returnCode = await session.getReturnCode();
      final File output = File(outputPath);
      if (ReturnCode.isSuccess(returnCode) && await output.exists() && await output.length() > 0) {
        return outputPath;
      }
    } catch (_) {
      // Plugin natif indisponible, disque plein, etc. : on retombe sur « pas de pochette ».
    }
    await _deleteQuietly(outputPath);
    return null;
  }

  Future<void> _deleteQuietly(String? path) async {
    if (path == null) return;
    try {
      final File partial = File(path);
      if (await partial.exists()) await partial.delete();
    } on FileSystemException {
      // Fichier verrouillé ou déjà parti : sans conséquence.
    }
  }
}
