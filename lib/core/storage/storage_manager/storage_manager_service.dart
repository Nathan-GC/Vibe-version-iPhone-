import 'dart:io';

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../platform/app_platform.dart';
import '../filename_sanitizer/filename_sanitizer.dart';
import '../music_folder_resolver.dart';
import 'imported_audio_file.dart';
import 'insufficient_storage_exception.dart';

/// Point de passage obligé pour toute copie/déplacement de fichier audio vers
/// /Music/AppFolder/ : garantit que [checkAvailableStorage] est vérifié avant
/// chaque écriture disque (Disk Guard) et centralise le renommage des fichiers.
class StorageManagerService {
  StorageManagerService({DiskSpacePlus? diskSpace, FilenameSanitizer? filenameSanitizer})
      : _diskSpace = diskSpace ?? DiskSpacePlus(),
        _filenameSanitizer = filenameSanitizer ?? FilenameSanitizer();

  final DiskSpacePlus _diskSpace;
  final FilenameSanitizer _filenameSanitizer;

  static final RegExp _illegalFilenameChars = RegExp(r'[\\/:*?"<>|]');

  Future<void> checkAvailableStorage(int requiredBytes) async {
    final double? freeMb = await _diskSpace.getFreeDiskSpace;
    // `disk_space_plus` (plugin tiers) peut renvoyer null si le canal natif
    // échoue — un espace "impossible à déterminer" n'est PAS un espace nul :
    // le traiter comme tel bloquait silencieusement TOUS les imports dès que
    // le plugin ratait un appel, sans aucun message clair côté utilisateur.
    // On laisse plutôt l'écriture disque elle-même échouer si le disque est
    // réellement plein.
    if (freeMb == null) return;

    final int availableBytes = (freeMb * 1024 * 1024).round();
    if (availableBytes < requiredBytes) {
      throw InsufficientStorageException(requiredBytes: requiredBytes, availableBytes: availableBytes);
    }
  }

  /// Déplace (`moveFile: true`) ou copie le fichier source vers /Music/AppFolder/,
  /// renommé en `{artist}-{title}.mp3` d'après le nom de fichier sanitizé
  /// (extension d'origine conservée sur iOS, voir [targetAudioExtensionFor]).
  /// Renvoie aussi ce résultat de sanitization (calculé sur le nom *original*)
  /// pour que le scan n'ait pas à le redériver depuis le nom déjà renommé.
  Future<ImportedAudioFile> importAudioFile(File sourceFile, {bool moveFile = false}) async {
    final int sizeBytes = await sourceFile.length();
    await checkAvailableStorage(sizeBytes);

    final Directory appFolder = await MusicFolderResolver.resolve();

    final SanitizedFilename sanitized = _filenameSanitizer.sanitizeFilename(p.basename(sourceFile.path));
    final String artist = sanitized.artist.replaceAll(_illegalFilenameChars, '');
    final String title = sanitized.title.replaceAll(_illegalFilenameChars, '');
    // Deux imports différents peuvent sanitizer vers le même nom (ex. deux
    // fichiers "Unknown" faute de tags/nom exploitable) — sans garde-fou,
    // le second écraserait silencieusement le premier sur disque.
    final String extension = targetAudioExtensionFor(sourceFile.path);
    final String targetPath = await _uniquePath(p.join(appFolder.path, '$artist-$title$extension'));

    final File imported = moveFile ? await sourceFile.rename(targetPath) : await sourceFile.copy(targetPath);
    return ImportedAudioFile(file: imported, sanitizedFromOriginalName: sanitized);
  }

  /// Extension du fichier importé dans /Music/AppFolder/.
  ///
  /// Android : toujours `.mp3` (renommage historique — ExoPlayer détecte le
  /// format au contenu, l'extension n'a pas d'incidence sur la lecture).
  /// iOS : extension d'origine conservée (repli `.mp3` si absente) —
  /// AVFoundation choisit son décodeur d'après l'extension d'un fichier
  /// local, un M4A/AAC/FLAC renommé en `.mp3` y devient illisible.
  @visibleForTesting
  static String targetAudioExtensionFor(String sourcePath) {
    if (!AppPlatform.isIOS) return '.mp3';
    final String extension = p.extension(sourcePath).toLowerCase();
    return extension.isEmpty ? '.mp3' : extension;
  }

  Future<String> _uniquePath(String path) async {
    if (!await File(path).exists()) return path;

    final String dir = p.dirname(path);
    final String base = p.basenameWithoutExtension(path);
    final String ext = p.extension(path);

    int counter = 2;
    String candidate = p.join(dir, '$base ($counter)$ext');
    while (await File(candidate).exists()) {
      counter++;
      candidate = p.join(dir, '$base ($counter)$ext');
    }
    return candidate;
  }

  /// Copie une image choisie via `image_picker` (Vibe Creator) dans
  /// `Music/AppFolder/vibe_backgrounds/<playlistId>.<ext>`, en écrasant toute
  /// image précédente pour cette playlist plutôt que d'accumuler des fichiers
  /// orphelins à chaque changement de fond.
  Future<File> importVibeBackgroundImage(File sourceFile, String playlistId) async {
    final int sizeBytes = await sourceFile.length();
    await checkAvailableStorage(sizeBytes);

    final Directory appFolder = await MusicFolderResolver.resolve();
    final Directory vibeFolder = Directory(p.join(appFolder.path, 'vibe_backgrounds'));
    if (!await vibeFolder.exists()) {
      await vibeFolder.create(recursive: true);
    }

    final String extension = p.extension(sourceFile.path);
    final String targetPath = p.join(vibeFolder.path, '$playlistId$extension');
    return sourceFile.copy(targetPath);
  }

  /// Copie une vidéo de fond choisie via `image_picker` (`pickVideo`, Vibe
  /// Creator — Section 4.3) dans le même dossier que [importVibeBackgroundImage]
  /// (extension différente, jamais de collision), en écrasant toute vidéo
  /// précédente pour cette playlist.
  Future<File> importVibeBackgroundVideo(File sourceFile, String playlistId) async {
    final int sizeBytes = await sourceFile.length();
    await checkAvailableStorage(sizeBytes);

    final Directory appFolder = await MusicFolderResolver.resolve();
    final Directory vibeFolder = Directory(p.join(appFolder.path, 'vibe_backgrounds'));
    if (!await vibeFolder.exists()) {
      await vibeFolder.create(recursive: true);
    }

    final String extension = p.extension(sourceFile.path);
    final String targetPath = p.join(vibeFolder.path, '$playlistId$extension');
    return sourceFile.copy(targetPath);
  }

  /// Copie une pochette choisie manuellement (édition via appui long sur un
  /// morceau) dans `Music/AppFolder/track_covers/<trackId>.<ext>`, en
  /// écrasant toute pochette précédemment importée pour ce morceau.
  Future<File> importTrackCoverImage(File sourceFile, String trackId) async {
    final int sizeBytes = await sourceFile.length();
    await checkAvailableStorage(sizeBytes);

    final Directory appFolder = await MusicFolderResolver.resolve();
    final Directory coversFolder = Directory(p.join(appFolder.path, 'track_covers'));
    if (!await coversFolder.exists()) {
      await coversFolder.create(recursive: true);
    }

    final String extension = p.extension(sourceFile.path);
    final String targetPath = p.join(coversFolder.path, '$trackId$extension');
    return sourceFile.copy(targetPath);
  }

  /// Copie une pochette de playlist choisie depuis l'éditeur (Design System)
  /// dans `Music/AppFolder/playlist_covers/<playlistId>.<ext>`, en écrasant
  /// toute pochette précédente pour cette playlist plutôt que d'accumuler des
  /// fichiers orphelins à chaque changement — même pattern que
  /// [importVibeBackgroundImage]/[importTrackCoverImage].
  Future<File> importPlaylistCoverImage(File sourceFile, String playlistId) async {
    final int sizeBytes = await sourceFile.length();
    await checkAvailableStorage(sizeBytes);

    final Directory appFolder = await MusicFolderResolver.resolve();
    final Directory coversFolder = Directory(p.join(appFolder.path, 'playlist_covers'));
    if (!await coversFolder.exists()) {
      await coversFolder.create(recursive: true);
    }

    final String extension = p.extension(sourceFile.path);
    final String targetPath = p.join(coversFolder.path, '$playlistId$extension');
    return sourceFile.copy(targetPath);
  }
}
