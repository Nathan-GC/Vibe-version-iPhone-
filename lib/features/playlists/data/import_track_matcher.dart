import '../../../core/identity/track_match_key.dart';
import '../../../core/playlist_manifest/manifest_track_ref.dart';
import '../../../core/storage/database/app_database.dart';
import '../domain/import_match_plan.dart';

/// Matching automatique des titres d'un manifeste JSON importé contre la
/// bibliothèque locale, basé sur le nom des titres (fonction pure : aucune
/// base de données, testable directement).
///
/// Association d'office UNIQUEMENT quand elle est sans ambiguïté :
///  1. même clé exacte (titre + album + artiste principal) -> `exact` ;
///  2. même titre normalisé (accents, ponctuation, "(Remastered)",
///     "feat. X" ignorés) ET même artiste, un seul candidat -> `confident`
///     (départagé par l'album s'il y en a plusieurs).
/// Tout le reste (plusieurs versions, même titre chez un autre artiste, rien
/// trouvé) part au matching manuel avec des suggestions.
///
/// Un morceau local n'est jamais associé d'office à deux titres du même
/// manifeste : une playlist ne peut contenir deux fois le même morceau.
class ImportTrackMatcher {
  ImportTrackMatcher(List<Track> library) {
    for (final Track track in library) {
      _byId[track.id] = track;
      (_byTitle[normalizeTrackTitle(track.title)] ??= []).add(track);
      for (final String artist in track.artists) {
        (_byArtist[normalizeArtistName(artist)] ??= []).add(track);
      }
    }
  }

  static const int _maxSuggestions = 5;

  final Map<String, Track> _byId = {};
  final Map<String, List<Track>> _byTitle = {};
  final Map<String, List<Track>> _byArtist = {};

  ImportMatchPlan plan(List<ManifestTrackRef> refs) {
    final Set<String> used = {};
    final List<ImportMatchEntry> entries = [];

    for (int index = 0; index < refs.length; index++) {
      final ImportMatchEntry entry = _matchOne(index, refs[index], used);
      final Track? match = entry.match;
      if (match != null) used.add(match.id);
      entries.add(entry);
    }
    return ImportMatchPlan(entries);
  }

  ImportMatchEntry _matchOne(int index, ManifestTrackRef ref, Set<String> used) {
    final Track? exact = _byId[ref.sanitizedKey];
    if (exact != null && !used.contains(exact.id)) {
      return ImportMatchEntry(index: index, ref: ref, status: ImportMatchStatus.exact, match: exact);
    }

    final String refArtist = normalizeArtistName(ref.artist);
    final List<Track> sameTitle = _byTitle[normalizeTrackTitle(ref.title)] ?? const [];
    final List<Track> sameTitleAndArtist = sameTitle.where((t) => _artistMatches(t, refArtist)).toList();
    final List<Track> available = sameTitleAndArtist.where((t) => !used.contains(t.id)).toList();

    if (available.length == 1) {
      return ImportMatchEntry(index: index, ref: ref, status: ImportMatchStatus.confident, match: available.single);
    }
    if (available.length > 1) {
      final String? album = ref.album;
      if (album != null && album.trim().isNotEmpty) {
        final String refAlbum = normalizeTrackTitle(album);
        final List<Track> sameAlbum = available.where((t) => normalizeTrackTitle(t.album) == refAlbum).toList();
        if (sameAlbum.length == 1) {
          return ImportMatchEntry(index: index, ref: ref, status: ImportMatchStatus.confident, match: sameAlbum.single);
        }
      }
      return ImportMatchEntry(index: index, ref: ref, status: ImportMatchStatus.ambiguous, candidates: available);
    }
    if (sameTitle.isNotEmpty) {
      return ImportMatchEntry(
        index: index,
        ref: ref,
        status: ImportMatchStatus.titleOnly,
        candidates: sameTitle.take(_maxSuggestions).toList(),
      );
    }
    return ImportMatchEntry(
      index: index,
      ref: ref,
      status: ImportMatchStatus.notFound,
      candidates: _similarTitlesSameArtist(ref, refArtist),
    );
  }

  /// Artiste identique après normalisation, ou l'un contenu dans l'autre au
  /// mot près ("Daft Punk" vs "Daft Punk, Pharrell Williams").
  static bool _artistMatches(Track track, String refArtist) {
    if (refArtist.isEmpty) return false;
    for (final String artist in track.artists) {
      final String local = normalizeArtistName(artist);
      if (local.isEmpty) continue;
      if (local == refArtist || ' $refArtist '.contains(' $local ') || ' $local '.contains(' $refArtist ')) {
        return true;
      }
    }
    return false;
  }

  /// Suggestions pour un titre introuvable : morceaux du même artiste dont
  /// le titre partage au moins un mot significatif (ex. un remix nommé
  /// autrement), les plus proches d'abord.
  List<Track> _similarTitlesSameArtist(ManifestTrackRef ref, String refArtist) {
    final List<Track> sameArtist = _byArtist[refArtist] ?? const [];
    if (sameArtist.isEmpty) return const [];
    final Set<String> refWords = _significantWords(ref.title);
    if (refWords.isEmpty) return const [];

    final List<(Track, int)> scored = [
      for (final Track track in sameArtist) (track, _significantWords(track.title).intersection(refWords).length),
    ]..removeWhere((pair) => pair.$2 == 0);
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(_maxSuggestions).map((pair) => pair.$1).toList();
  }

  static Set<String> _significantWords(String title) =>
      normalizeTrackTitle(title).split(' ').where((word) => word.length > 2).toSet();
}
