import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../database/track_repository.dart';
import '../file_scanner/device_root_resolver.dart';
import '../file_scanner/file_scanner.dart';

final Provider<ImportableAudioFinder> importableAudioFinderProvider = Provider<ImportableAudioFinder>((ref) {
  return ImportableAudioFinder(trackRepository: ref.watch(trackRepositoryProvider));
});

/// Un fichier audio du téléphone pas encore en bibliothèque, tel que listé par
/// l'écran d'import manuel. Aucun tag lu (lent sur des milliers de fichiers) :
/// ils le sont à l'import.
class ImportableAudioFile {
  const ImportableAudioFile({
    required this.path,
    required this.name,
    required this.folder,
    required this.modified,
    required this.size,
  });

  final String path;

  /// Nom du fichier sans extension.
  final String name;

  /// Dossier parent relatif à la racine du stockage (ex. "Download" ou
  /// "Music/Daft Punk", séparateur "/"), "" si le fichier est à la racine.
  final String folder;

  final DateTime modified;
  final int size;
}

/// SHA-256 d'un fichier, hors du thread UI (fonction top-level pour [compute],
/// comme dans FullDeviceScanService).
Future<String> _hashFile(String path) async {
  final Digest digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

/// Recense les fichiers audio du téléphone que la bibliothèque ne contient pas
/// encore (écran « Importer des MP3 »).
///
/// Mêmes fichiers que le scan plein-appareil du premier lancement (racine de
/// [DeviceRootResolver], extensions et exclusions de [FileScanner]), moins ceux
/// déjà en bibliothèque : voir [find].
class ImportableAudioFinder {
  ImportableAudioFinder({
    required TrackRepository trackRepository,
    Future<Directory?> Function()? resolveRoot,
    FileScanner? fileScanner,
  })  : _trackRepository = trackRepository,
        _resolveRoot = resolveRoot ?? DeviceRootResolver.resolve,
        _fileScanner = fileScanner ?? FileScanner();

  final TrackRepository _trackRepository;
  final Future<Directory?> Function() _resolveRoot;
  final FileScanner _fileScanner;

  /// Fichiers hachés en parallèle (isolates) — évite de saturer l'appareil.
  static const int _maxConcurrentHashing = 4;

  /// Fichiers `stat`és en parallèle.
  static const int _statBatchSize = 32;

  /// Fichiers ajoutables, plus récemment modifiés d'abord (arrivée sur le
  /// téléphone), à date égale par nom. Jamais d'exception pour un fichier
  /// illisible ou disparu en cours de route : il est simplement ignoré.
  ///
  /// Un fichier est masqué s'il est déjà en bibliothèque :
  /// - même chemin qu'un `tracks.file_path` (titre indexé sur place) ;
  /// - chemin en liste noire ;
  /// - même contenu qu'un fichier de la bibliothèque. Un import manuel COPIE
  ///   le fichier dans le dossier de l'app sous « Artiste-Titre.mp3 » : le nom
  ///   d'origine est perdu, seul le contenu relie l'original à sa copie. La
  ///   taille départage d'abord (un `stat` sans lecture) ; le SHA-256 n'est
  ///   calculé que pour deux fichiers de taille égale.
  Future<List<ImportableAudioFile>> find() async {
    final Directory? root = await _resolveRoot();
    if (root == null || !await root.exists()) return const [];

    final FileScanResult scanned = await _fileScanner.scan(root);

    // Chemins connus lus en bloc : une requête pour toute la bibliothèque,
    // pas une par fichier du téléphone.
    final List<({String filePath, String? fileHash, int lastModifiedEpochMs})> libraryRefs =
        await _trackRepository.fetchFileRefs();
    final Set<String> hiddenPaths = {
      for (final ref in libraryRefs) ref.filePath,
      ...await _trackRepository.blacklistedFilePaths(),
    };

    final List<_Candidate> candidates = await _statAll([
      for (final File file in scanned.audioFiles)
        if (!hiddenPaths.contains(file.path)) file,
    ]);

    final List<_Candidate> remaining = await _dropContentDuplicates(candidates, libraryRefs);

    final List<ImportableAudioFile> result = [
      for (final _Candidate candidate in remaining)
        ImportableAudioFile(
          path: candidate.file.path,
          name: p.basenameWithoutExtension(candidate.file.path),
          folder: _relativeFolder(root, candidate.file),
          modified: candidate.stat.modified,
          size: candidate.stat.size,
        ),
    ];
    result.sort((a, b) {
      final int byDate = b.modified.compareTo(a.modified);
      if (byDate != 0) return byDate;
      final int byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.path.compareTo(b.path);
    });
    return result;
  }

  /// `stat` de chaque fichier ; ceux devenus illisibles ou disparus depuis le
  /// recensement sont écartés.
  Future<List<_Candidate>> _statAll(List<File> files) async {
    final List<_Candidate> result = [];
    for (int i = 0; i < files.length; i += _statBatchSize) {
      final List<_Candidate?> batch = await Future.wait([
        for (final File file in files.skip(i).take(_statBatchSize)) _statOrNull(file),
      ]);
      result.addAll(batch.whereType<_Candidate>());
    }
    return result;
  }

  Future<_Candidate?> _statOrNull(File file) async {
    try {
      final FileStat stat = await file.stat();
      return stat.type == FileSystemEntityType.file ? _Candidate(file, stat) : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Retire les candidats dont le contenu est celui d'un fichier de la
  /// bibliothèque (copies renommées par l'import manuel).
  Future<List<_Candidate>> _dropContentDuplicates(
    List<_Candidate> candidates,
    List<({String filePath, String? fileHash, int lastModifiedEpochMs})> libraryRefs,
  ) async {
    if (candidates.isEmpty || libraryRefs.isEmpty) return candidates;

    // Taille de chaque fichier de la bibliothèque, lue UNE fois ; un fichier
    // disparu n'a plus rien à comparer et est ignoré.
    final Map<int, List<_LibraryFile>> librarySizes = {};
    for (int i = 0; i < libraryRefs.length; i += _statBatchSize) {
      final List<_LibraryFile?> batch = await Future.wait([
        for (final ref in libraryRefs.skip(i).take(_statBatchSize)) _libraryFileOrNull(ref),
      ]);
      for (final _LibraryFile file in batch.whereType<_LibraryFile>()) {
        librarySizes.putIfAbsent(file.size, () => []).add(file);
      }
    }

    // Seuls les candidats dont la taille existe en bibliothèque méritent une
    // lecture ; tous les autres sont forcément nouveaux.
    final List<_Candidate> sameSize = [
      for (final _Candidate candidate in candidates)
        if (librarySizes.containsKey(candidate.stat.size)) candidate,
    ];
    final Set<_Candidate> duplicates = {};
    for (int i = 0; i < sameSize.length; i += _maxConcurrentHashing) {
      final List<_Candidate> batch = sameSize.skip(i).take(_maxConcurrentHashing).toList();
      final List<bool> isDuplicate = await Future.wait([
        for (final _Candidate candidate in batch) _hasSameContentInLibrary(candidate, librarySizes[candidate.stat.size]!),
      ]);
      for (int j = 0; j < batch.length; j++) {
        if (isDuplicate[j]) duplicates.add(batch[j]);
      }
    }
    return [
      for (final _Candidate candidate in candidates)
        if (!duplicates.contains(candidate)) candidate,
    ];
  }

  Future<_LibraryFile?> _libraryFileOrNull(({String filePath, String? fileHash, int lastModifiedEpochMs}) ref) async {
    try {
      final FileStat stat = await File(ref.filePath).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      // L'empreinte mémorisée ne vaut que si le fichier n'a pas bougé depuis
      // (même mtime) ; souvent nulle, elle ne sert qu'à éviter une relecture.
      final bool storedHashIsFresh =
          ref.fileHash != null && ref.lastModifiedEpochMs == stat.modified.millisecondsSinceEpoch;
      return _LibraryFile(ref.filePath, stat.size, storedHashIsFresh ? ref.fileHash : null);
    } on FileSystemException {
      return null;
    }
  }

  /// Vrai si [candidate] a le même SHA-256 que l'un des fichiers de
  /// bibliothèque de même taille [sameSize]. Candidat illisible → faux : il est
  /// gardé, mieux vaut proposer un fichier en trop que d'en cacher un nouveau.
  Future<bool> _hasSameContentInLibrary(_Candidate candidate, List<_LibraryFile> sameSize) async {
    final String? candidateHash = await _hashOrNull(candidate.file.path);
    if (candidateHash == null) return false;
    for (final _LibraryFile libraryFile in sameSize) {
      if (await libraryFile.hash(_hashOrNull) == candidateHash) return true;
    }
    return false;
  }

  Future<String?> _hashOrNull(String path) async {
    try {
      return await compute(_hashFile, path);
    } on Object {
      // Fichier disparu ou illisible entre le recensement et la lecture.
      return null;
    }
  }

  /// Dossier parent de [file] relatif à [root], séparateur "/".
  String _relativeFolder(Directory root, File file) {
    final String relative = p.relative(file.parent.path, from: root.path).replaceAll('\\', '/');
    return relative == '.' ? '' : relative;
  }
}

class _Candidate {
  const _Candidate(this.file, this.stat);

  final File file;
  final FileStat stat;
}

/// Fichier de la bibliothèque dont l'empreinte est calculée une seule fois,
/// même demandée par plusieurs candidats de même taille.
class _LibraryFile {
  _LibraryFile(this.path, this.size, String? knownHash) : _hash = knownHash == null ? null : Future.value(knownHash);

  final String path;
  final int size;
  Future<String?>? _hash;

  Future<String?> hash(Future<String?> Function(String path) hasher) => _hash ??= hasher(path);
}
