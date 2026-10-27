import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/shared/onboarding_storage.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_auto_enricher.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/scanner/library_scan_service.dart';
import '../../../core/storage/scanner/scanned_track.dart';
import '../../settings/data/auto_enrich_preference.dart';

/// Progression du nouveau scan : [done] titres parcourus sur [total].
typedef RescanProgress = ({int done, int total});

/// « Nouveau scan » de la bibliothèque après une mise à jour : relit l'identité
/// de CHAQUE titre (tags du fichier, sinon nouveau découpage du nom de fichier)
/// et relance la correspondance iTunes (US + FR, E1-E6), même pour les titres
/// déjà enrichis. Règle : si l'enrichissement donne un résultat, il est
/// appliqué ([TrackRepository.applyRescanResult]) ; sinon l'ancien
/// enrichissement est conservé tel quel.
///
/// - Une seule fois par version ([currentRescanVersion]) : le drapeau n'est posé
///   qu'à la FIN d'une passe complète. Une installation neuve utilise déjà le
///   nouveau pipeline : l'onboarding appelle [markDone].
/// - Reprenable : titres parcourus par id croissant, curseur (dernier id traité)
///   enregistré après chaque titre. Une passe interrompue (app fermée, réseau
///   coupé, interrupteur sur OFF) reprend après le curseur au lancement suivant.
/// - Jamais bloquée à vie : seuls les échecs réseau TRANSITOIRES arrêtent la
///   passe (les erreurs définitives sont déjà une « absence de correspondance »,
///   voir [TrackAutoEnricher.lookupMatch]) ; un titre qui échoue ainsi à
///   [maxConsecutiveFailures] passes de suite est sauté — mais SEULS comptent
///   les échecs où le serveur a répondu (5xx, 403, 429, [MatchLookup.serverResponded]).
///   Une absence de réponse (hors ligne, mode avion, métro) arrête la passe sans
///   toucher au compteur : ce n'est pas la faute du titre, trois lancements hors
///   ligne ne doivent pas le priver à vie de la correction (AN-30).
/// - Pochettes : dès qu'un titre est traité, sa pochette http(s) en base est
///   rapatriée sur l'appareil, sans attendre la fin de la passe (le localiseur
///   automatique, lui, attend ce scan) — sinon des icônes « note » pendant
///   toute sa durée, l'affichage n'utilisant plus le réseau.
/// - RGPD : onboarding terminé ET interrupteur « Enrichissement automatique » ON,
///   relus AVANT CHAQUE TITRE (l'utilisateur peut couper en cours de route) ;
///   sinon la passe s'arrête sans se terminer.
/// - Jamais touchés : les choix explicites de l'utilisateur (statuts
///   `enrichedManual*`), les fichiers absents/illisibles, les titres dont le
///   nom reste trop ambigu pour interroger iTunes (même règle qu'à l'import).
class LibraryRescanService {
  LibraryRescanService({
    required TrackRepository repository,
    required LibraryScanService scanService,
    required TrackAutoEnricher enricher,
    Future<void> Function()? onFinished,
    void Function(RescanProgress? progress)? onProgress,
    Future<bool> Function()? gate,
    Future<bool> Function(String trackId)? localizeCover,
  })  : _repository = repository,
        _scanService = scanService,
        _enricher = enricher,
        _onFinished = onFinished,
        _onProgress = onProgress,
        _gate = gate ?? _defaultGate,
        _localizeCover = localizeCover;

  /// Version du nouveau scan : à incrémenter pour en relancer un après une
  /// future évolution du découpage/de la correspondance.
  static const int currentRescanVersion = 1;
  static const String doneVersionKey = 'library.rescan_done_version';
  static const String cursorKey = 'library.rescan_cursor';

  /// Filet de sécurité (AN-19) : titre qui suit le curseur et nombre de passes
  /// CONSÉCUTIVES où il a échoué en [_Outcome.serverFailed]. Au
  /// [maxConsecutiveFailures]-ième échec de suite, il est sauté. Persistants
  /// (SharedPreferences) car les passes sont séparées par des lancements de l'app.
  static const String failIdKey = 'library.rescan_fail_id';
  static const String failCountKey = 'library.rescan_fail_count';
  static const int maxConsecutiveFailures = 3;

  /// Statuts posés par un choix explicite de l'utilisateur dans l'éditeur :
  /// jamais écrasés par une passe automatique.
  static const Set<EnrichmentStatus> _userChosenStatuses = {
    EnrichmentStatus.enrichedManualEdit,
    EnrichmentStatus.enrichedManualItunes,
    EnrichmentStatus.enrichedManualMusicBrainz,
  };

  final TrackRepository _repository;
  final LibraryScanService _scanService;
  final TrackAutoEnricher _enricher;
  final Future<void> Function()? _onFinished;
  final void Function(RescanProgress? progress)? _onProgress;
  final Future<bool> Function() _gate;

  /// Rapatrie la pochette http(s) d'un titre (`RemoteCoverLocalizer.localizeTrack`,
  /// branché dans le provider) — un simple callback plutôt que le localiseur
  /// lui-même, qui importe déjà ce service (pas de dépendance circulaire).
  final Future<bool> Function(String trackId)? _localizeCover;

  bool _running = false;

  /// Garde RGPD, relue avant chaque titre : onboarding terminé ET interrupteur ON.
  static Future<bool> _defaultGate() async =>
      !await OnboardingStorage().isFirstLaunch() && await AutoEnrichPreference.isEnabled();

  /// `true` tant que le nouveau scan de la version courante n'est pas terminé.
  /// Lu aussi par le rapatriement automatique des pochettes, qui attend la fin
  /// pour ne pas télécharger une pochette sur le point d'être remplacée.
  static Future<bool> isPending() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(doneVersionKey) ?? 0) < currentRescanVersion;
  }

  /// Marque le nouveau scan comme FAIT sans le jouer (installation neuve : ses
  /// titres ont été importés par le pipeline courant).
  static Future<void> markDone() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(doneVersionKey, currentRescanVersion);
    await prefs.remove(cursorKey);
    await prefs.remove(failIdKey);
    await prefs.remove(failCountKey);
  }

  /// Lance (ou reprend) le nouveau scan s'il est en attente. Sans effet si une
  /// passe tourne déjà, si le scan est fait, ou si la garde RGPD refuse.
  Future<void> runIfPending() async {
    if (_running) return;
    _running = true;
    bool completed = false;
    try {
      if (!await isPending() || !await _gate()) return;
      completed = await _run();
    } finally {
      _running = false;
      // Bannière retirée dans tous les cas (fin, arrêt réseau, garde refusée),
      // avant le rapatriement des pochettes qui peut durer.
      _onProgress?.call(null);
    }
    if (!completed) return;
    try {
      await _onFinished?.call();
    } catch (_) {
      // Le rapatriement des pochettes se rattrapera au prochain déclencheur.
    }
  }

  /// Une passe. `true` si elle est allée au bout (drapeau posé, curseur effacé).
  Future<bool> _run() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<Track> tracks = await _repository.fetchAllTracks();
    // Ordre stable (id croissant) : le curseur reste valable d'un lancement à
    // l'autre même si des titres sont ajoutés ou retirés entre-temps.
    tracks.sort((a, b) => a.id.compareTo(b.id));

    final String? cursor = prefs.getString(cursorKey);
    int index = cursor == null ? 0 : tracks.indexWhere((t) => t.id.compareTo(cursor) > 0);
    if (index < 0) index = tracks.length;

    _onProgress?.call((done: index, total: tracks.length));
    for (; index < tracks.length; index++) {
      // Relue avant CHAQUE titre : un interrupteur coupé en cours de route
      // arrête les connexions immédiatement.
      if (!await _gate()) return false;
      final Track track = tracks[index];

      final _Outcome outcome = await _process(track);
      // Échec réseau : on s'arrête SANS avancer le curseur, ce titre sera
      // retenté au prochain lancement (inutile d'insister titre après titre)…
      // sauf s'il échoue ainsi à [maxConsecutiveFailures] passes de suite : il
      // est alors sauté (curseur avancé plus bas) plutôt que de bloquer le scan,
      // la bannière et le rapatriement des pochettes pour toujours.
      // Hors ligne (aucune réponse du serveur) : même arrêt, mais compteur
      // intact, ni incrémenté ni remis à zéro (AN-30) — une coupure intercalée
      // entre deux échecs serveur ne les rend pas « non consécutifs ».
      if (outcome == _Outcome.offline) return false;
      if (outcome == _Outcome.serverFailed && await _recordFailureAndShouldRetry(prefs, track.id)) return false;
      // Titre traité (ou sauté par le filet) : le compteur repart de zéro, seuls
      // des échecs d'un même titre SANS traitement entre eux sont « consécutifs ».
      await _clearFailure(prefs);

      // Traité (ou sauté) : sa pochette http(s) est rapatriée tout de suite, sans
      // attendre la fin du scan (AN-20).
      await _localizeRemoteCover(track.id);

      await prefs.setString(cursorKey, track.id);
      _onProgress?.call((done: index + 1, total: tracks.length));
    }

    await prefs.setInt(doneVersionKey, currentRescanVersion);
    await prefs.remove(cursorKey);
    await prefs.remove(failIdKey);
    await prefs.remove(failCountKey);
    return true;
  }

  /// Compte un échec réseau de plus pour [trackId] (compteur remis à 1 si c'est
  /// un autre titre que le précédent). `true` : le titre sera retenté au
  /// prochain lancement ; `false` : seuil atteint, il doit être sauté.
  Future<bool> _recordFailureAndShouldRetry(SharedPreferences prefs, String trackId) async {
    final int previous = prefs.getString(failIdKey) == trackId ? (prefs.getInt(failCountKey) ?? 0) : 0;
    final int count = previous + 1;
    if (count >= maxConsecutiveFailures) return false;
    await prefs.setString(failIdKey, trackId);
    await prefs.setInt(failCountKey, count);
    return true;
  }

  Future<void> _clearFailure(SharedPreferences prefs) async {
    if (prefs.containsKey(failIdKey)) await prefs.remove(failIdKey);
    if (prefs.containsKey(failCountKey)) await prefs.remove(failCountKey);
  }

  /// Rapatrie la pochette de [trackId] si, EN BASE (après l'éventuelle
  /// application d'une correspondance), c'est une URL http(s) — héritée de la
  /// version précédente ou posée à l'instant. La garde RGPD du titre vient
  /// d'être vérifiée dans [_run]. Un échec n'arrête jamais le scan : la passe
  /// finale de rapatriement (`onFinished`) retentera.
  Future<void> _localizeRemoteCover(String trackId) async {
    final Future<bool> Function(String trackId)? localize = _localizeCover;
    if (localize == null) return;
    try {
      final String cover = (await _repository.findById(trackId))?.coverArtPath ?? '';
      if (cover.startsWith('http://') || cover.startsWith('https://')) await localize(trackId);
    } catch (_) {
      // Base fermée, réseau, disque plein… : sans conséquence pour le scan.
    }
  }

  Future<_Outcome> _process(Track track) async {
    if (_userChosenStatuses.contains(track.enrichmentStatus)) return _Outcome.skipped;

    final ScannedTrack? identity;
    try {
      final File file = File(track.filePath);
      if (!await file.exists()) return _Outcome.skipped;
      identity = await _scanService.identify(file);
    } catch (_) {
      // Fichier illisible : conservé tel quel, sans bloquer le reste de la bibliothèque.
      return _Outcome.skipped;
    }
    // Illisible/trop court, ou nom trop ambigu pour interroger iTunes (même
    // règle qu'à l'import : requiresReview n'est jamais enrichi automatiquement).
    if (identity == null || identity.requiresUserReview) return _Outcome.skipped;

    final MatchLookup lookup;
    try {
      lookup = await _enricher.lookupMatch(
        title: identity.title,
        artists: identity.artists,
        localDurationMs: track.durationSeconds * 1000,
        skipDurationCheck: TrackAutoEnricher.mentionsVideo(p.basename(track.filePath)),
      );
    } catch (_) {
      // Exception inattendue de l'enrichisseur : comptée, pour que le filet
      // protège le scan d'un titre qui la provoquerait systématiquement.
      return _Outcome.serverFailed;
    }
    if (lookup.networkFailed) return lookup.serverResponded ? _Outcome.serverFailed : _Outcome.offline;

    // Aucune correspondance fiable : l'ancien enrichissement est conservé.
    final EnrichmentMatch? match = lookup.match;
    if (match == null) return _Outcome.skipped;

    try {
      await _repository.applyRescanResult(
        track.id,
        title: identity.title,
        artists: identity.artists,
        album: identity.album,
        genre: identity.genre,
        match: match.result,
        swapped: match.swapped,
      );
    } catch (_) {
      // Écriture refusée (base fermée, contrainte) : le titre garde son état.
    }
    return _Outcome.applied;
  }
}

/// [serverFailed] : échec transitoire où le serveur a répondu (compté par le
/// filet) ; [offline] : aucune réponse (non compté, voir AN-30).
enum _Outcome { skipped, applied, serverFailed, offline }
