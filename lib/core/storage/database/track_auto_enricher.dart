import 'dart:io' show IOException;

import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../networking/metadata_api_client/metadata_api_client.dart';
import '../../shared/text/encoding_fixer.dart';
import '../../networking/metadata_api_client/online_track_result.dart';
import '../../networking/metadata_api_client/track_match_confidence.dart';
import 'musicbrainz_auto_enricher.dart';
import 'track_enricher.dart';
import 'track_repository.dart';

/// Enrichissement iTunes partagé entre l'action manuelle de la Bibliothèque
/// (bouton "Enrichir") et l'enrichissement automatique de post-import (voir
/// LibraryScreen._importFiles, OnboardingScanController.start) — évite de
/// dupliquer la construction de requête et le filtre de confiance à chaque
/// appelant.
class TrackAutoEnricher implements TrackEnricher {
  TrackAutoEnricher({
    required MetadataApiClient metadataApiClient,
    required TrackRepository trackRepository,
    MusicBrainzAutoEnricher? fallback,
  })  : _metadataApiClient = metadataApiClient,
        _trackRepository = trackRepository,
        _fallback = fallback;

  final MetadataApiClient _metadataApiClient;
  final TrackRepository _trackRepository;

  /// Repli quand iTunes ne trouve rien de fiable (ordre : iTunes, puis
  /// MusicBrainz) — `null` : iTunes seul.
  final MusicBrainzAutoEnricher? _fallback;

  /// Nombre de résultats iTunes examinés PAR CATALOGUE (voir [_catalogCountries]) :
  /// la recherche en texte libre n'a pas le filtre d'artiste exact de
  /// `searchByArtist`/`searchAlbumsByArtist`, donc la bonne correspondance
  /// n'est pas toujours en tête — on en regarde plusieurs et on ne retient
  /// que le premier qui passe [TrackMatchConfidence] plutôt que le premier
  /// tout court. Poussé à 15 (puis 10, au lieu de 5, avant) : la vitesse n'est
  /// pas la priorité, et plus de candidats donne à la fois plus de chances de
  /// trouver le bon et plus de matière au garde-fou anti-ambiguïté de
  /// [TrackMatchConfidence.pickBestMatch] (artiste local inconnu).
  static const int candidateLimit = 15;

  /// Catalogues iTunes interrogés en parallèle, dans l'ordre de priorité de la
  /// fusion : un morceau (surtout francophone) peut n'exister, ou n'avoir la
  /// bonne pochette/les bonnes métadonnées, que dans l'un des deux stores.
  static const List<String> _catalogCountries = ['US', 'FR'];

  // Clause "feat./ft./featuring ..." en fin de titre — retirée seulement de
  // la *requête* envoyée à iTunes, jamais du titre stocké/affiché (voir
  // [_searchTitleFor]). Vérifié empiriquement : une requête du type "VALD
  // PANDEMONIUM RELOADED feat. VLADIMIR CAUCHEMAR & TODI3FOR" ne trouve rien,
  // alors que "VALD PANDEMONIUM RELOADED" seul trouve le morceau.
  //
  // Deux formes : le mot isolé (`\b`, « feat. », « ft », « featuring ») OU, pour
  // les noms de fichier sans espace (« Stanft.Dido »), « ft. »/« feat. » collé à
  // un caractère alphanumérique ou une parenthèse (lookbehind) ET suivi d'un
  // point obligatoire — sans lui, « Daft Punk », « Left » ou « Feather »
  // seraient tronqués. Le lookahead `(?=[\s\S])` exige au moins un caractère
  // après le marqueur : une clause vide n'a rien à retirer.
  static final RegExp _trailingFeatureClauseForQuery = RegExp(
    r'[\(\[]?\s*(?:\b(?:feat\.?|ft\.?|featuring)\b|(?<=[A-Za-z0-9\)\]])(?:ft|feat)\.)(?=[\s\S]).*$',
    caseSensitive: false,
  );

  // Mention explicite d'un clip dans le nom de fichier ("Official Video",
  // "Lyric Video", "(Video)"...), y compris en forme compacte
  // ("OfficialMusicVideo") : la durée d'un clip (intro/outro parlés) n'est pas
  // celle du morceau studio, le contrôle de durée y serait faussement négatif.
  // "video" seul ne compte que comme mot entier : "VIDEOCLUB" n'en est pas un.
  static final RegExp _videoMention = RegExp(
    r'official[\s_.-]*(music[\s_.-]*)?video|music[\s_.-]*video|lyrics?[\s_.-]*video|video[\s_.-]*clip|'
    r'clip[\s_.-]*officiel|visuali[sz]er|(?<![a-z0-9])video(?![a-z0-9])',
    caseSensitive: false,
  );

  /// `true` si [fileName] mentionne explicitement une vidéo/un clip (aussi
  /// utilisé par le nouveau scan de la bibliothèque, voir LibraryRescanService).
  static bool mentionsVideo(String fileName) => _videoMention.hasMatch(fileName);

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Cherche la meilleure correspondance iTunes pour ([title], [artists]) et
  /// enrichit pochette HD / genre / époque en base. Non destructif dans ce
  /// cas (voir [TrackRepository.enrichFromOnlineMetadata]) : sûr à relancer.
  ///
  /// La recherche iTunes part simultanément sur deux catalogues (US et FR,
  /// même requête) dont les résultats sont fusionnés et dédoublonnés avant le
  /// choix de la meilleure correspondance — voir [_searchCandidates].
  ///
  /// Si la correspondance Artiste+Titre ne donne rien de fiable, l'inversion
  /// Titre/Artiste est testée LOCALEMENT sur ces mêmes candidats, avant
  /// d'abandonner — certains noms de fichiers inversent Titre et Artiste (ex.
  /// "Halo - Beyoncé.mp3", où "Halo" est en réalité le titre et "Beyoncé"
  /// l'artiste, vérifié empiriquement sur de vrais fichiers, structurellement
  /// indiscernable d'un nom bien ordonné). Une requête texte libre ne dépend
  /// pas de l'ordre des mots : les candidats déjà reçus contiennent le morceau
  /// dans les deux cas, d'où l'absence de seconde requête réseau. Si l'ordre
  /// inversé trouve une correspondance fiable, c'est une confirmation externe
  /// assez forte pour corriger Titre/Artiste stockés plutôt que seulement
  /// enrichir la pochette — voir [TrackRepository.correctReversedTitleArtist]
  /// — contrairement à la correspondance primaire, qui elle ne touche jamais
  /// Titre/Artiste. Dans le pire cas où l'ordre inversé ne trouve rien de
  /// fiable non plus, rien n'est appliqué.
  ///
  /// `singleAttempt` (utilisé par `OnboardingScanController.start`, scan
  /// initial) : aucune reprise interne de [MetadataApiClient] sur échec/403
  /// pour les deux requêtes — un fichier non trouvé ou en échec est
  /// immédiatement marqué `pending` ("À enrichir") plutôt que de faire
  /// attendre l'écran d'onboarding le temps d'une reprise (jusqu'à plusieurs
  /// minutes en cas de blocage de débit iTunes). L'inversion locale ci-dessus
  /// reste active dans ce mode : elle ne coûte aucune requête.
  @override
  Future<bool> enrichTrack({
    required String trackId,
    required String title,
    required List<String> artists,
    bool singleAttempt = false,
  }) async {
    // Circuit-breaker (voir TrackRepository.shouldAttemptEnrichment) : un
    // morceau `failedPermanently` (tentatives épuisées) ou `requiresReview`
    // (nom de fichier trop ambigu) ne doit plus jamais déclencher de requête
    // API tant qu'une correction manuelle ne l'a pas réinitialisé.
    if (!await _trackRepository.shouldAttemptEnrichment(trackId)) return false;

    // Durée du fichier (ffprobe) et nom de fichier d'origine : garde-fou de
    // durée de TrackMatchConfidence. Piste introuvable : aucun contrôle de durée.
    final track = await _trackRepository.findById(trackId);
    final int? localDurationMs = track == null ? null : track.durationSeconds * 1000;
    final bool skipDurationCheck = track != null && mentionsVideo(_baseName(track.filePath));

    final MatchLookup lookup = await lookupMatch(
      title: title,
      artists: artists,
      localDurationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
      retryOnFailure: !singleAttempt,
    );
    if (lookup.networkFailed) {
      // Échec TRANSITOIRE (coupure, timeout, 5xx, blocage 403/429) sans qu'aucun
      // catalogue ait répondu : en mode normal, déjà
      // retentée en interne par MetadataApiClient, donc ne compte pas comme une
      // tentative épuisée, sans quoi un simple blocage temporaire iTunes (403)
      // finirait par bannir des morceaux parfaitement enrichissables une fois
      // la limitation levée. En [singleAttempt] (scan initial), aucune reprise
      // interne n'a eu lieu : l'échec est définitif pour ce passage, donc
      // consigné comme tel pour que le morceau reste visible dans "À
      // enrichir" plutôt que de rester dans un flou non comptabilisé.
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: singleAttempt);
    }

    final EnrichmentMatch? match = lookup.match;
    if (match == null) {
      // Recherche aboutie sans correspondance fiable (ni directe, ni inversée,
      // ni artiste/titre exploitable pour tenter l'inversion) : tentative comptée.
      // Y compris quand les deux catalogues ont échoué sur des erreurs DÉFINITIVES
      // (400/404, réponse illisible…, voir [lookupMatch]) : réessayer échouerait
      // identiquement, donc l'échec consomme une tentative comme une absence de
      // correspondance — le titre finit en revue manuelle au lieu de boucler.
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: true);
    }

    // Correspondance directe : jamais destructif pour Titre/Artiste. Inversée :
    // confirmation externe assez forte pour les corriger (revérifiée en base).
    final bool ok = match.swapped
        ? await _trackRepository.correctReversedTitleArtist(trackId, match.result)
        : await _trackRepository.enrichFromOnlineMetadata(trackId, match.result);
    await _trackRepository.recordEnrichmentOutcome(trackId, success: ok, source: EnrichmentSource.itunes);
    return ok;
  }

  /// Recherche iTunes (US + FR, voir [_searchCandidates]) puis décision
  /// ([decide]) pour ([title], [artists]), SANS rien écrire en base ni toucher
  /// au circuit-breaker : brique publique réutilisable par un futur « nouveau
  /// scan de la bibliothèque » qui veut seulement savoir ce que l'enrichisseur
  /// décidérait.
  ///
  /// Le résultat distingue un échec réseau TRANSITOIRE sans réponse d'aucun
  /// catalogue ([MatchLookup.networkFailed], rien n'a pu être jugé, à retenter
  /// plus tard) d'une recherche aboutie dont [MatchLookup.match] est
  /// éventuellement `null` (aucune correspondance fiable, ou catalogues en
  /// échec DÉFINITIF — erreur HTTP de requête, réponse illisible : inutile de
  /// réessayer, voir [_searchCandidates]). [retryOnFailure] `false` : aucune reprise interne
  /// de [MetadataApiClient] (voir `singleAttempt` d'[enrichTrack]).
  Future<MatchLookup> lookupMatch({
    required String title,
    required List<String> artists,
    int? localDurationMs,
    bool skipDurationCheck = false,
    bool retryOnFailure = true,
  }) async {
    final String artist = artists.isNotEmpty ? artists.first : '';
    final _SearchOutcome search = await _searchCandidates(
      queryArtist: artist,
      queryTitle: title,
      retryOnFailure: retryOnFailure,
    );
    final List<OnlineTrackResult>? candidates = search.candidates;
    if (candidates == null) return MatchLookup.networkFailed(serverResponded: search.serverResponded);
    return MatchLookup.completed(decide(
      title: title,
      artists: artists,
      candidates: candidates,
      localDurationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
    ));
  }

  /// Décision PURE (ni réseau, ni base) : parmi [candidates], renvoie la
  /// correspondance primaire (`swapped: false`) ; à défaut, si l'artiste est
  /// connu (non vide, différent de `Unknown`) et le titre non vide, celle de
  /// l'inversion Titre/Artiste testée localement sur les mêmes candidats
  /// (`swapped: true`) ; sinon `null`.
  ///
  /// Inversion : le TITRE local joue le rôle d'artiste. Il est d'abord nettoyé
  /// par [TrackMatchConfidence.artistTextForSwap] (« Lady Gaga(Feat.Colby
  /// O'Donis) » devient « Lady Gaga », sinon le score d'artiste s'effondre),
  /// mais la parité des mots-clés de version compare le titre d'ORIGINE au
  /// titre du candidat — sans quoi « Ian Asher (Remix) » deviendrait « Desire »
  /// (pickBestMatch ne contrôle que les mots-clés du titre inversé).
  @visibleForTesting
  static EnrichmentMatch? decide({
    required String title,
    required List<String> artists,
    required List<OnlineTrackResult> candidates,
    int? localDurationMs,
    bool skipDurationCheck = false,
  }) {
    final OnlineTrackResult? primary = TrackMatchConfidence.pickBestMatch(
      localTitle: title,
      localArtists: artists,
      candidates: candidates,
      localDurationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
    );
    if (primary != null) return EnrichmentMatch(primary, swapped: false);

    final String artist = artists.isNotEmpty ? artists.first : '';
    final bool hasBothFields = artist.isNotEmpty && artist != 'Unknown' && title.isNotEmpty;
    if (!hasBothFields) return null;

    final OnlineTrackResult? swapped = TrackMatchConfidence.pickBestMatch(
      localTitle: artist,
      localArtists: [TrackMatchConfidence.artistTextForSwap(title)],
      candidates: candidates,
      localDurationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
    );
    if (swapped == null || !TrackMatchConfidence.sameVersionKeywords(title, swapped.title)) return null;
    return EnrichmentMatch(swapped, swapped: true);
  }

  /// iTunes n'a rien donné : repli MusicBrainz s'il est configuré. Une seule
  /// tentative est comptée pour l'ensemble iTunes + MusicBrainz, et
  /// seulement si une recherche a réellement abouti ([attemptConsumed] côté
  /// iTunes, ou réponse MusicBrainz sans correspondance) — une erreur réseau
  /// des deux côtés ne consomme rien.
  Future<bool> _fallbackOrFail(
    String trackId,
    String title,
    List<String> artists, {
    required bool attemptConsumed,
  }) async {
    final bool? found = await _fallback?.tryMatch(trackId: trackId, title: title, artists: artists);
    if (found == true) {
      await _trackRepository.recordEnrichmentOutcome(trackId, success: true, source: EnrichmentSource.musicBrainz);
      return true;
    }
    if (attemptConsumed || found == false) {
      await _trackRepository.recordEnrichmentOutcome(trackId, success: false, source: EnrichmentSource.itunes);
    }
    return false;
  }

  /// Interroge en parallèle les catalogues de [_catalogCountries] (même
  /// requête) et renvoie les candidats fusionnés : ceux du premier catalogue
  /// d'abord, puis ceux du suivant, sans doublon, dans la limite de
  /// `candidateLimit` par catalogue.
  ///
  /// Dédoublonnage par `trackId` iTunes (le même enregistrement garde son id
  /// d'un store à l'autre) ; à défaut d'id, par titre|artiste|album en
  /// minuscules. Garder le premier vu fait primer le catalogue prioritaire.
  ///
  /// Si un catalogue échoue et pas l'autre, on exploite celui qui a répondu
  /// (mieux vaut une moitié de réponse que rien). `null` uniquement si TOUS
  /// ont échoué : l'appelant applique alors son traitement d'erreur réseau.
  /// Requête vide : aucun appel réseau, liste vide.
  ///
  /// Quand AUCUN catalogue n'a répondu, la nature des échecs tranche : au moins
  /// un échec TRANSITOIRE (voir [_isTransientFailure]) → `null` (réessayer plus
  /// tard a un sens) ; que des échecs DÉFINITIFS (400/404, réponse illisible…)
  /// → liste vide, c'est-à-dire une recherche « aboutie sans correspondance » :
  /// la renvoyer en `null` ferait réessayer éternellement une requête qui
  /// échouera toujours (AN-19 : le nouveau scan de la bibliothèque restait
  /// bloqué sur le même titre).
  ///
  /// [_SearchOutcome.serverResponded] (AN-30) précise un échec transitoire : au
  /// moins un catalogue a-t-il reçu une réponse d'ERREUR du serveur (5xx, 403,
  /// 429) ou n'y a-t-il eu aucune réponse (hors ligne, timeout) ?
  Future<_SearchOutcome> _searchCandidates({
    required String queryArtist,
    required String queryTitle,
    required bool retryOnFailure,
  }) async {
    // Réparation du mojibake CP850/Mac Roman limitée à la requête : le titre
    // local servant au rapprochement et les données stockées restent intacts.
    // Sur la requête ENTIÈRE : un nom de fichier corrompu l'est de bout en
    // bout, une signature dans l'artiste doit aussi réparer le titre ("BeyoncÇ"
    // + "áa n'en vaut pas la peine").
    final String query = EncodingFixer.fix([
      if (queryArtist.isNotEmpty && queryArtist != 'Unknown') queryArtist,
      _searchTitleFor(queryTitle),
    ].join(' ').trim());
    if (query.isEmpty) return (candidates: const <OnlineTrackResult>[], serverResponded: false);

    final List<_CatalogOutcome> outcomes = await Future.wait([
      for (final String country in _catalogCountries) _searchCatalog(query, country, retryOnFailure),
    ]);
    if (outcomes.every((outcome) => outcome.results == null)) {
      return (
        candidates: outcomes.any((outcome) => outcome.transientFailure) ? null : const <OnlineTrackResult>[],
        serverResponded: outcomes.any((outcome) => outcome.serverResponded),
      );
    }

    return (candidates: mergeCandidates(outcomes.map((outcome) => outcome.results)), serverResponded: false);
  }

  /// Fusionne les résultats par catalogue (dans l'ordre fourni, un catalogue
  /// en échec valant `null`) en gardant la première occurrence de chaque
  /// morceau — voir [_searchCandidates] pour la règle de dédoublonnage.
  @visibleForTesting
  static List<OnlineTrackResult> mergeCandidates(Iterable<List<OnlineTrackResult>?> perCatalog) {
    final Set<String> seen = {};
    final List<OnlineTrackResult> merged = [];
    for (final List<OnlineTrackResult>? results in perCatalog) {
      for (final OnlineTrackResult result in results ?? const <OnlineTrackResult>[]) {
        if (seen.add(_dedupKey(result))) merged.add(result);
      }
    }
    return merged;
  }

  /// Une requête sur un catalogue ; une erreur ne fait jamais échouer l'autre
  /// catalogue (voir [_searchCandidates]) : elle devient un résultat `null`
  /// accompagné de sa nature (transitoire ou définitive).
  Future<_CatalogOutcome> _searchCatalog(String query, String country, bool retryOnFailure) async {
    try {
      final List<OnlineTrackResult> results = await _metadataApiClient.search(
        query,
        limit: candidateLimit,
        retryOnFailure: retryOnFailure,
        country: country,
      );
      return (results: results, transientFailure: false, serverResponded: false);
    } catch (error) {
      return (
        results: null,
        transientFailure: _isTransientFailure(error),
        serverResponded: _isServerResponseFailure(error),
      );
    }
  }

  /// `true` si l'échec peut disparaître en réessayant plus tard : pas de
  /// réponse du tout (coupure, timeouts, connexion refusée), erreur serveur
  /// 5xx, ou blocage de débit iTunes (403 et 429). MÊME classification que
  /// `MetadataApiClient._isTransient`/`_isRateLimited` (qui documente les
  /// autres codes HTTP comme de vraies erreurs de requête), complétée des
  /// erreurs d'entrée/sortie qu'un `DioExceptionType.unknown` peut envelopper.
  ///
  /// Tout le reste est DÉFINITIF : autre code HTTP (400, 404…), réponse
  /// illisible (JSON invalide, structure inattendue), annulation, exception
  /// inattendue. Réessayer ne changerait rien, et une erreur définitive
  /// traitée comme transitoire bloquerait le nouveau scan à vie sur ce titre.
  static bool _isTransientFailure(Object error) {
    if (error is! DioException) return false;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final int? status = error.response?.statusCode;
        return status != null && (status >= 500 || status == 403 || status == 429);
      case DioExceptionType.unknown:
        return error.error is IOException;
      // transformTimeout : décodage local de la réponse trop long, pas un
      // problème de réseau — définitif comme une réponse illisible.
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.transformTimeout:
        return false;
    }
  }

  /// `true` si l'échec est une réponse d'ERREUR du serveur (5xx, 403, 429) :
  /// le réseau fonctionne, c'est le service qui refuse ou qui est en panne. À
  /// l'inverse d'une absence de réponse (coupure, mode avion, timeouts,
  /// `IOException`), qui dit seulement que l'appareil est hors ligne (AN-30).
  static bool _isServerResponseFailure(Object error) {
    if (error is! DioException || error.type != DioExceptionType.badResponse) return false;
    return _isTransientFailure(error);
  }

  static String _dedupKey(OnlineTrackResult result) => result.trackId != null
      ? 'id:${result.trackId}'
      : 'key:${result.title}|${result.artist}|${result.album ?? ''}'.toLowerCase();

  static String _searchTitleFor(String title) => title.replaceFirst(_trailingFeatureClauseForQuery, '').trim();
}

/// Correspondance retenue par [TrackAutoEnricher.decide] : le candidat iTunes
/// et le sens dans lequel il a été validé ([swapped] : Titre/Artiste inversés
/// par rapport au fichier local).
class EnrichmentMatch {
  const EnrichmentMatch(this.result, {required this.swapped});

  final OnlineTrackResult result;
  final bool swapped;
}

/// Issue de la requête sur UN catalogue : [results] (`null` si elle a échoué)
/// et, dans ce cas, [transientFailure] (échec qui peut disparaître en
/// réessayant, voir `TrackAutoEnricher._isTransientFailure`).
/// [serverResponded] : cet échec est une réponse d'erreur du serveur (5xx, 403,
/// 429), pas une absence de réponse.
typedef _CatalogOutcome = ({List<OnlineTrackResult>? results, bool transientFailure, bool serverResponded});

/// Issue de [TrackAutoEnricher._searchCandidates] : [candidates] (`null` =
/// échec transitoire) et, dans ce cas, [serverResponded] (au moins un catalogue
/// a reçu une réponse d'erreur du serveur).
typedef _SearchOutcome = ({List<OnlineTrackResult>? candidates, bool serverResponded});

/// Résultat de [TrackAutoEnricher.lookupMatch] : soit un échec réseau
/// TRANSITOIRE sans aucun catalogue ayant répondu ([networkFailed], rien n'a pu
/// être jugé, réessayer plus tard a un sens), soit une recherche aboutie dont
/// [match] vaut `null` quand aucun candidat n'est fiable (y compris quand tous
/// les catalogues ont échoué sur des erreurs DÉFINITIVES).
///
/// [serverResponded] (AN-30, significatif seulement si [networkFailed]) : vrai
/// si au moins un catalogue a reçu une réponse d'erreur du serveur (5xx, 403,
/// 429) ; faux si AUCUN n'a répondu (coupure, mode avion, timeouts). Le nouveau
/// scan s'en sert pour ne compter comme « échec » que le premier cas : être
/// hors ligne n'est la faute d'aucun titre.
class MatchLookup {
  const MatchLookup.networkFailed({required this.serverResponded})
      : networkFailed = true,
        match = null;
  const MatchLookup.completed(this.match)
      : networkFailed = false,
        serverResponded = false;

  final bool networkFailed;
  final bool serverResponded;
  final EnrichmentMatch? match;
}
