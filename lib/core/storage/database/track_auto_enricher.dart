import '../../networking/metadata_api_client/metadata_api_client.dart';
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

  /// Nombre de résultats iTunes examinés par tentative : la recherche en
  /// texte libre n'a pas le filtre d'artiste exact de
  /// `searchByArtist`/`searchAlbumsByArtist`, donc la bonne correspondance
  /// n'est pas toujours en tête — on en regarde plusieurs et on ne retient
  /// que le premier qui passe [TrackMatchConfidence] plutôt que le premier
  /// tout court. Poussé à 10 (au lieu de 5) : la vitesse n'est pas la
  /// priorité, et plus de candidats donne à la fois plus de chances de
  /// trouver le bon et plus de matière au garde-fou anti-ambiguïté de
  /// [TrackMatchConfidence.pickBestMatch] (artiste local inconnu).
  static const int candidateLimit = 10;

  // Clause "feat./ft./featuring ..." en fin de titre — retirée seulement de
  // la *requête* envoyée à iTunes, jamais du titre stocké/affiché (voir
  // [_searchTitleFor]). Vérifié empiriquement : une requête du type "VALD
  // PANDEMONIUM RELOADED feat. VLADIMIR CAUCHEMAR & TODI3FOR" ne trouve rien,
  // alors que "VALD PANDEMONIUM RELOADED" seul trouve le morceau.
  static final RegExp _trailingFeatureClauseForQuery = RegExp(
    r'[\(\[]?\s*\b(?:feat\.?|ft\.?|featuring)\b.*$',
    caseSensitive: false,
  );

  /// Cherche la meilleure correspondance iTunes pour ([title], [artists]) et
  /// enrichit pochette HD / genre / époque en base. Non destructif dans ce
  /// cas (voir [TrackRepository.enrichFromOnlineMetadata]) : sûr à relancer.
  ///
  /// Si la recherche Artiste+Titre ne trouve rien de fiable, retente une
  /// seconde fois avec les deux inversés avant d'abandonner — certains noms
  /// de fichiers inversent Titre et Artiste (ex. "Halo - Beyoncé.mp3", où
  /// "Halo" est en réalité le titre et "Beyoncé" l'artiste, vérifié
  /// empiriquement sur de vrais fichiers, structurellement indiscernable
  /// d'un nom bien ordonné). Si CETTE tentative trouve une correspondance
  /// fiable, c'est une confirmation externe assez forte pour corriger
  /// Titre/Artiste stockés plutôt que seulement enrichir la pochette — voir
  /// [TrackRepository.correctReversedTitleArtist] — contrairement à la
  /// tentative primaire, qui elle ne touche jamais Titre/Artiste. Dans le pire
  /// cas où l'ordre inversé ne trouve rien de fiable non plus, rien n'est
  /// appliqué.
  ///
  /// `singleAttempt` (utilisé par `OnboardingScanController.start`, scan
  /// initial) : impose exactement une requête réseau, sans la reprise
  /// inversée Titre/Artiste ci-dessus ni les reprises internes de
  /// [MetadataApiClient] sur échec/403 — un fichier non trouvé ou en échec
  /// est immédiatement marqué `pending` ("À enrichir") plutôt que de faire
  /// attendre l'écran d'onboarding le temps d'une reprise (jusqu'à plusieurs
  /// minutes en cas de blocage de débit iTunes).
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

    OnlineTrackResult? primaryMatch;
    try {
      primaryMatch = await _search(
        localTitle: title,
        localArtists: artists,
        queryArtist: artist,
        queryTitle: title,
        retryOnFailure: !singleAttempt,
      );
    } catch (_) {
      // Erreur réseau/API : en mode normal, déjà retentée en interne par
      // MetadataApiClient, donc ne compte pas comme une tentative épuisée,
      // sans quoi un simple blocage temporaire iTunes (403) finirait par
      // bannir des morceaux parfaitement enrichissables une fois la
      // limitation levée. En [singleAttempt] (scan initial), aucune reprise
      // interne n'a eu lieu : l'échec est définitif pour ce passage, donc
      // consigné comme tel pour que le morceau reste visible dans "À
      // enrichir" plutôt que de rester dans un flou non comptabilisé.
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: singleAttempt);
    }
    if (primaryMatch != null) {
      final bool ok = await _trackRepository.enrichFromOnlineMetadata(trackId, primaryMatch);
      await _trackRepository.recordEnrichmentOutcome(trackId, success: ok, source: EnrichmentSource.itunes);
      return ok;
    }

    final bool hasBothFields = artist.isNotEmpty && artist != 'Unknown' && title.isNotEmpty;
    if (singleAttempt || !hasBothFields) {
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: true);
    }

    OnlineTrackResult? swappedMatch;
    try {
      swappedMatch = await _search(localTitle: artist, localArtists: [title], queryArtist: title, queryTitle: artist);
    } catch (_) {
      return _fallbackOrFail(trackId, title, artists, attemptConsumed: false);
    }
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

  Future<OnlineTrackResult?> _search({
    required String localTitle,
    required List<String> localArtists,
    required String queryArtist,
    required String queryTitle,
    bool retryOnFailure = true,
  }) async {
    final String query = [
      if (queryArtist.isNotEmpty && queryArtist != 'Unknown') queryArtist,
      _searchTitleFor(queryTitle),
    ].join(' ').trim();
    if (query.isEmpty) return null;

    final List<OnlineTrackResult> results = await _metadataApiClient.search(
      query,
      limit: candidateLimit,
      retryOnFailure: retryOnFailure,
    );
    return TrackMatchConfidence.pickBestMatch(localTitle: localTitle, localArtists: localArtists, candidates: results);
  }

  static String _searchTitleFor(String title) => title.replaceFirst(_trailingFeatureClauseForQuery, '').trim();
}
