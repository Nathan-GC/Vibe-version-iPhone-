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
  /// [appFolderResolver] : surchargeable en test (sinon [MusicFolderResolver.resolve]).
  StorageManagerService({
    DiskSpacePlus? diskSpace,
    FilenameSanitizer? filenameSanitizer,
    Future<Directory> Function()? appFolderResolver,
  })  : _diskSpace = diskSpace ?? DiskSpacePlus(),
        _filenameSanitizer = filenameSanitizer ?? FilenameSanitizer(),
        _resolveAppFolder = appFolderResolver ?? MusicFolderResolver.resolve;

  final DiskSpacePlus _diskSpace;
  final FilenameSanitizer _filenameSanitizer;
  final Future<Directory> Function() _resolveAppFolder;

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

    final Directory appFolder = await _resolveAppFolder();

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

  /// Chemin neuf `Music/AppFolder/<folderName>/<id>_<epochMs><extension>`, unique
  /// à chaque appel : réécrire toujours le même chemin cassait la vidéo en cours
  /// de lecture (ExoPlayer garde le fichier ouvert) et laissait le cache d'images
  /// Flutter (indexé par chemin) servir l'ancienne image.
  Future<String> newOwnedFilePath(String folderName, String id, String extension) async {
    final Directory appFolder = await _resolveAppFolder();
    final Directory folder = Directory(p.join(appFolder.path, folderName));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    int stamp = DateTime.now().millisecondsSinceEpoch;
    String path = p.join(folder.path, '${id}_$stamp$extension');
    // Deux appels dans la même milliseconde ne doivent pas produire le même nom.
    while (await File(path).exists()) {
      stamp++;
      path = p.join(folder.path, '${id}_$stamp$extension');
    }
    return path;
  }

  /// Supprime, dans `<folderName>/`, les fichiers de CET [id] autres que
  /// [keepPath] : ancien format `<id><ext>` et nouveau `<id>_<chiffres><ext>`.
  /// Comparaison exacte du préfixe (les ids de titres contiennent eux-mêmes des
  /// `_`) : le reste après `<id>_` doit être uniquement numérique, donc un autre
  /// id qui commence pareil n'est jamais touché. Au mieux : erreurs d'E/S ignorées.
  Future<void> deleteOtherOwnedFiles(String folderName, String id, {required String keepPath}) =>
      _deleteOwned(folderName, id, keepPath: keepPath);

  Future<void> _deleteOwned(
    String folderName,
    String id, {
    required String keepPath,
    bool Function(String extension)? onlyExtension,
  }) async {
    try {
      final Directory appFolder = await _resolveAppFolder();
      final Directory folder = Directory(p.join(appFolder.path, folderName));
      if (!await folder.exists()) return;
      final String keep = keepPath.isEmpty ? '' : p.normalize(keepPath);
      await for (final FileSystemEntity entity in folder.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!_isOwnedFileName(p.basename(entity.path), id)) continue;
        if (onlyExtension != null && !onlyExtension(p.extension(entity.path))) continue;
        if (keep.isNotEmpty && p.normalize(entity.path) == keep) continue;
        try {
          await entity.delete();
        } on FileSystemException {
          // Fichier verrouillé ou déjà parti : le prochain import réessaiera.
        }
      }
    } on FileSystemException {
      // Nettoyage purement opportuniste.
    }
  }

  static bool _isOwnedFileName(String fileName, String id) {
    final String name = p.basenameWithoutExtension(fileName);
    if (name == id) return true;
    if (!name.startsWith('${id}_')) return false;
    final String suffix = name.substring(id.length + 1);
    return suffix.isNotEmpty && suffix.codeUnits.every((int c) => c >= 0x30 && c <= 0x39);
  }

  static const Set<String> _videoExtensions = {'.mp4', '.mov', '.m4v', '.webm', '.mkv', '.3gp'};
  static bool _isVideoExtension(String ext) => _videoExtensions.contains(ext.toLowerCase());

  /// [sameKind] : image et vidéo de fond d'une même playlist cohabitent dans
  /// `vibe_backgrounds/` ; importer l'une ne doit pas supprimer l'autre.
  Future<File> _importOwned(
    File sourceFile,
    String folderName,
    String id, {
    bool Function(String extension)? sameKind,
  }) async {
    final int sizeBytes = await sourceFile.length();
    await checkAvailableStorage(sizeBytes);

    final String targetPath = await newOwnedFilePath(folderName, id, p.extension(sourceFile.path));
    final File copied = await sourceFile.copy(targetPath);
    await _deleteOwned(folderName, id, keepPath: copied.path, onlyExtension: sameKind);
    return copied;
  }

  /// Copie une image choisie via `image_picker` (Vibe Creator) dans
  /// `Music/AppFolder/vibe_backgrounds/<playlistId>_<epochMs>.<ext>` (chemin
  /// unique), puis supprime les anciens fichiers de cette playlist.
  Future<File> importVibeBackgroundImage(File sourceFile, String playlistId) =>
      _importOwned(sourceFile, 'vibe_backgrounds', playlistId, sameKind: (String e) => !_isVideoExtension(e));

  /// Vidéo de fond (Vibe Creator, Section 4.3) : même dossier et même principe
  /// que [importVibeBackgroundImage]. Le chemin unique force
  /// `VibeVideoBackground` à recharger la vidéo.
  Future<File> importVibeBackgroundVideo(File sourceFile, String playlistId) =>
      _importOwned(sourceFile, 'vibe_backgrounds', playlistId, sameKind: _isVideoExtension);

  /// Pochette choisie manuellement (appui long sur un morceau) dans
  /// `Music/AppFolder/track_covers/`.
  Future<File> importTrackCoverImage(File sourceFile, String trackId) =>
      _importOwned(sourceFile, 'track_covers', trackId);

  /// Pochette de playlist choisie depuis l'éditeur dans
  /// `Music/AppFolder/playlist_covers/`.
  Future<File> importPlaylistCoverImage(File sourceFile, String playlistId) =>
      _importOwned(sourceFile, 'playlist_covers', playlistId);
}
