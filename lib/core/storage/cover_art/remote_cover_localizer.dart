import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../features/library/data/library_providers.dart' show storageManagerServiceProvider;
import '../../../features/library/data/library_rescan_service.dart';
import '../../../features/settings/data/auto_enrich_preference.dart';
import '../../networking/app_dio.dart';
import '../../shared/onboarding_storage.dart';
import '../database/app_database.dart';
import '../database/track_repository.dart';
import '../storage_manager/storage_manager_service.dart';

/// Dossier (sous `Music/AppFolder/`) des pochettes possédées par l'app.
const String _coverFolder = 'track_covers';

/// Taille demandée à Apple : 600x600 suffit largement à l'affichage et
/// divise l'espace disque par ~3 par rapport au 1000x1000 de l'enrichissement.
const int _itunesCoverSize = 600;

/// Rapatrie sur l'appareil les pochettes trouvées en ligne : l'URL http(s)
/// enregistrée par l'enrichissement est téléchargée UNE fois, écrite dans
/// `track_covers/` puis remplacée en base par le chemin local. Ainsi
/// l'affichage ne passe plus jamais par le réseau (RGPD : plus d'adresse IP
/// envoyée à Apple/CAA à chaque écran, et l'interrupteur « Enrichissement
/// automatique » sur OFF n'a plus rien à retenir).
class RemoteCoverLocalizer {
  RemoteCoverLocalizer({
    required TrackRepository repository,
    required StorageManagerService storage,
    Dio? dio,
    Future<bool> Function()? automaticGate,
  })  : _repository = repository,
        _storage = storage,
        _dio = dio ?? createAppDio(),
        _automaticGate = automaticGate ?? _defaultAutomaticGate;

  final TrackRepository _repository;
  final StorageManagerService _storage;
  final Dio _dio;
  final Future<bool> Function() _automaticGate;

  /// Passe en cours (une seule à la fois) et demande reçue pendant qu'elle
  /// tournait : relancée juste après, pour ne pas rater des titres arrivés
  /// entre-temps.
  Future<int>? _pass;
  bool _again = false;

  /// Garde-fou RGPD des passes AUTOMATIQUES, relu avant chaque titre :
  /// onboarding terminé (aucun réseau avant) ET interrupteur ON (droit
  /// d'opposition) ET nouveau scan de la bibliothèque terminé : tant qu'il est
  /// en attente, les pochettes http(s) vont peut-être être remplacées, inutile
  /// de les télécharger (une passe de rapatriement suit sa fin). Une action
  /// explicite ([localizeTrack] seul, éditeur) n'y est pas soumise.
  static Future<bool> _defaultAutomaticGate() async =>
      !await OnboardingStorage().isFirstLaunch() &&
      await AutoEnrichPreference.isEnabled() &&
      !await LibraryRescanService.isPending();

  /// Rapatrie la pochette de [trackId] si c'est une URL http(s). `true` si le
  /// titre pointe désormais vers un fichier local ; toute erreur donne
  /// `false`, sans fichier partiel et sans exception.
  Future<bool> localizeTrack(String trackId) async {
    String? targetPath;
    try {
      final Track? track = await _repository.findById(trackId);
      final String url = track?.coverArtPath ?? '';
      if (!_isRemote(url)) return false;

      final Response<List<int>> response = await _dio.get<List<int>>(
        _requestUrl(url),
        options: Options(responseType: ResponseType.bytes),
      );
      final List<int>? bytes = response.data;
      final String? contentType = response.headers.value(Headers.contentTypeHeader);
      // Une page d'erreur HTML servie en 200 ne doit pas devenir une « pochette ».
      if (bytes == null || bytes.isEmpty || (contentType != null && !contentType.startsWith('image/'))) {
        return false;
      }

      await _storage.checkAvailableStorage(bytes.length);
      targetPath = await _storage.newOwnedFilePath(_coverFolder, trackId, _extensionFor(url, contentType));
      await File(targetPath).writeAsBytes(bytes, flush: true);

      // La pochette a pu être changée à la main pendant le téléchargement :
      // le fichier téléchargé est alors jeté, jamais écrit par-dessus.
      if (!await _repository.replaceRemoteCoverWithLocal(trackId, url, targetPath)) {
        await _deleteQuietly(targetPath);
        return false;
      }
      await _storage.deleteOtherOwnedFiles(_coverFolder, trackId, keepPath: targetPath);
      return true;
    } catch (_) {
      // Réseau, disque plein, base fermée... : la pochette reste telle quelle
      // et sera retentée à la prochaine passe.
      if (targetPath != null) await _deleteQuietly(targetPath);
      return false;
    }
  }

  /// Passe automatique : traite l'un après l'autre tous les titres à pochette
  /// http(s) et renvoie le nombre rapatrié. Un appel pendant une passe en
  /// cours n'en lance pas une seconde (il en demande une de rattrapage).
  Future<int> localizePending() {
    final Future<int>? running = _pass;
    if (running != null) {
      _again = true;
      return running;
    }
    return _pass = _runPasses().whenComplete(() => _pass = null);
  }

  Future<int> _runPasses() async {
    int localized = 0;
    do {
      _again = false;
      try {
        for (final String id in await _repository.trackIdsWithRemoteCover()) {
          if (!await _automaticGate()) return localized;
          if (await localizeTrack(id)) localized++;
        }
      } catch (_) {
        // Base fermée en cours de route : on s'arrête, la prochaine passe reprendra.
        return localized;
      }
    } while (_again);
    return localized;
  }

  static bool _isRemote(String path) => path.startsWith('http://') || path.startsWith('https://');

  /// Les URL iTunes (`…/1000x1000bb.jpg`) sont redemandées en 600x600.
  static String _requestUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.host.contains('mzstatic')) return url;
    return url.replaceFirstMapped(RegExp(r'/(\d+)x(\d+)bb'), (Match m) {
      final bool alreadySmall = (int.tryParse(m[1]!) ?? 0) <= _itunesCoverSize;
      return alreadySmall ? m[0]! : '/${_itunesCoverSize}x${_itunesCoverSize}bb';
    });
  }

  /// Extension d'après le type MIME annoncé, sinon d'après l'URL, sinon `.jpg`.
  static String _extensionFor(String url, String? contentType) {
    if (contentType != null) {
      if (contentType.contains('png')) return '.png';
      if (contentType.contains('webp')) return '.webp';
      if (contentType.contains('jpeg') || contentType.contains('jpg')) return '.jpg';
    }
    final String ext = p.extension(Uri.tryParse(url)?.path ?? '').toLowerCase();
    return const {'.jpg', '.jpeg', '.png', '.webp'}.contains(ext) ? ext : '.jpg';
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Fichier verrouillé ou déjà parti : sans conséquence.
    }
  }
}

final Provider<RemoteCoverLocalizer> remoteCoverLocalizerProvider = Provider<RemoteCoverLocalizer>((ref) {
  return RemoteCoverLocalizer(
    repository: ref.watch(trackRepositoryProvider),
    storage: ref.watch(storageManagerServiceProvider),
  );
});
