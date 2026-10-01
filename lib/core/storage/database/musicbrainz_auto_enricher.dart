import '../../networking/metadata_api_client/online_track_result.dart';
import '../../networking/metadata_api_client/track_match_confidence.dart';
import '../../networking/musicbrainz/musicbrainz_client.dart';
import 'track_enricher.dart';
import 'track_repository.dart';

/// Enrichissement MusicBrainz + Cover Art Archive — même circuit-breaker et
/// même filtre de confiance que l'iTunes ([TrackRepository.
/// shouldAttemptEnrichment], [TrackMatchConfidence]) : les deux sources
/// renvoient un Titre/Artiste structuré, comparable au morceau local.
/// Utilisé seul (source "MusicBrainz" choisie pour "Enrichir tout") ou en
/// repli de TrackAutoEnricher quand iTunes ne trouve rien.
class MusicBrainzAutoEnricher implements TrackEnricher {
  MusicBrainzAutoEnricher({required MusicBrainzClient client, required TrackRepository trackRepository})
      : _client = client,
        _trackRepository = trackRepository;

  final MusicBrainzClient _client;
  final TrackRepository _trackRepository;

  @override
  Future<bool> enrichTrack({required String trackId, required String title, required List<String> artists}) async {
    if (!await _trackRepository.shouldAttemptEnrichment(trackId)) return false;

    final bool? found = await tryMatch(trackId: trackId, title: title, artists: artists);
    // Erreur réseau (503 de limitation compris) : ne consomme pas de
    // tentative, comme pour l'iTunes.
    if (found == null) return false;
    await _trackRepository.recordEnrichmentOutcome(trackId, success: found, source: EnrichmentSource.musicBrainz);
    return found;
  }

  /// Recherche et applique la meilleure correspondance, SANS toucher au
  /// circuit-breaker (laissé à l'appelant) : `true` appliquée, `false`
  /// recherche aboutie sans correspondance fiable, `null` erreur réseau.
  Future<bool?> tryMatch({required String trackId, required String title, required List<String> artists}) async {
    final List<OnlineTrackResult> results;
    try {
      results = await _client.searchRecordings(artist: artists.isNotEmpty ? artists.first : '', title: title);
    } catch (_) {
      return null;
    }
    final OnlineTrackResult? match =
        TrackMatchConfidence.pickBestMatch(localTitle: title, localArtists: artists, candidates: results);
    if (match == null) return false;
    return _trackRepository.enrichFromOnlineMetadata(trackId, match);
  }
}
