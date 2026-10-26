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
  static final RegExp _trailingFeatureClauseForQuery = RegExp(
    r'[\(\[]?\s*\b(?:feat\.?|ft\.?|featuring)\b.*$',
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

  /// `true` si [fileName] mentionne explicitement une vidéo/un clip.
  @visibleForTesting
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

    final String artist = artists.isNotEmpty ? artists.first : '';

    // Durée du fichier (ffprobe) et nom de fichier d'origine : garde-fou de
    // durée de TrackMatchConfidence. Piste introuvable : aucun contrôle de durée.
    final track = await _trackRepository.findById(trackId);
    final int? localDurationMs = track == null ? null : track.durationSeconds * 1000;
    final bool skipDurationCheck = track != null && mentionsVideo(_baseName(track.filePath));

    final List<OnlineTrackResult>? candidates = await _searchCandidates(
      queryArtist: artist,
      queryTitle: title,
      retryOnFailure: !singleAttempt,
    );
    if (candidates == null) {
      // Erreur réseau/API sur les DEUX catalogues : en mode normal, déjà
      // retentée en interne par MetadataApiClient, donc ne compte pas comme une
      // tentative épuisée, sans quoi un simple blocage temporaire iTunes (403)
      // finirait par bannir des morceaux parfaitement enrichissables une fois
      // la limitation levée. En [singleAttempt] (scan initial), aucune reprise
      // interne n'a eu lieu : l'échec est définitif pour ce passage, donc
      // consigné comme tel pour que le morceau reste visible dans "À
      // enrichir" plutôt que de rester dans un flou non comptabilisé.
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: singleAttempt);
    }

    final OnlineTrackResult? primaryMatch = TrackMatchConfidence.pickBestMatch(
      localTitle: title,
      localArtists: artists,
      candidates: candidates,
      localDurationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
    );
    if (primaryMatch != null) {
      final bool ok = await _trackRepository.enrichFromOnlineMetadata(trackId, primaryMatch);
      await _trackRepository.recordEnrichmentOutcome(trackId, success: ok, source: EnrichmentSource.itunes);
      return ok;
    }

    final bool hasBothFields = artist.isNotEmpty && artist != 'Unknown' && title.isNotEmpty;
    if (!hasBothFields) {
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: true);
    }

    // Inversion Titre/Artiste testée en local, sur les mêmes candidats.
    final OnlineTrackResult? swappedMatch = TrackMatchConfidence.pickBestMatch(
      localTitle: artist,
      localArtists: [title],
      candidates: candidates,
      localDurationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
    );
    if (swappedMatch == null) {
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: true);
    }

    final bool ok = await _trackRepository.correctReversedTitleArtist(trackId, swappedMatch);
    await _trackRepository.recordEnrichmentOutcome(trackId, success: ok, source: EnrichmentSource.itunes);
    return ok;
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
  Future<List<OnlineTrackResult>?> _searchCandidates({
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
    if (query.isEmpty) return const [];

    final List<List<OnlineTrackResult>?> perCatalog = await Future.wait([
      for (final String country in _catalogCountries) _searchCatalog(query, country, retryOnFailure),
    ]);
    if (perCatalog.every((results) => results == null)) return null;

    return mergeCandidates(perCatalog);
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

  /// Une requête sur un catalogue ; une erreur devient `null` pour ne pas
  /// faire échouer l'autre catalogue (voir [_searchCandidates]).
  Future<List<OnlineTrackResult>?> _searchCatalog(String query, String country, bool retryOnFailure) async {
    try {
      return await _metadataApiClient.search(
        query,
        limit: candidateLimit,
        retryOnFailure: retryOnFailure,
        country: country,
      );
    } catch (_) {
      return null;
    }
  }

  static String _dedupKey(OnlineTrackResult result) => result.trackId != null
      ? 'id:${result.trackId}'
      : 'key:${result.title}|${result.artist}|${result.album ?? ''}'.toLowerCase();

  static String _searchTitleFor(String title) => title.replaceFirst(_trailingFeatureClauseForQuery, '').trim();
}
