import '../../../core/storage/database/app_database.dart';

/// Regroupement des morceaux d'un artiste par album, pour le filtre "Albums"
/// (Étape 3), trié du plus récent au plus ancien. Réutilisé pour la
/// discographie en ligne (Profil Artiste, `ArtistMetadataApi.fetchAlbums`) :
/// `tracks` reste vide dans ce cas (pas de morceaux locaux), les champs
/// `artworkUrl`/`label`/`trackCount`/`collectionId` prennent le relais.
class AlbumGroup {
  const AlbumGroup({
    required this.album,
    required this.releaseYear,
    required this.tracks,
    this.artworkUrl,
    this.label,
    this.trackCount,
    this.collectionId,
  });

  final String album;
  final int releaseYear;
  final List<Track> tracks;
  final String? artworkUrl;
  final String? label;
  final int? trackCount;
  // Id de collection iTunes — permet de récupérer les morceaux d'un album de
  // la discographie en ligne via `ArtistMetadataApi.fetchAlbumTracks`. Absent
  // pour un regroupement local (voir groupTracksByAlbum).
  final int? collectionId;
}

List<AlbumGroup> groupTracksByAlbum(List<Track> tracks) {
  final Map<String, List<Track>> grouped = {};
  for (final track in tracks) {
    grouped.putIfAbsent(track.album, () => []).add(track);
  }

  final List<AlbumGroup> groups = grouped.entries.map((entry) {
    // Ordre officiel d'album (disque puis piste) quand au moins un numéro est
    // connu (enrichissement iTunes, voir TrackRepository) ; `List.sort` n'étant
    // pas garanti stable, on évite de trier quand tout le monde est à 0 —
    // ça mélangerait arbitrairement un album jamais enrichi.
    final bool hasOrderingInfo = entry.value.any((t) => t.trackNumber > 0);
    final List<Track> ordered = !hasOrderingInfo
        ? entry.value
        : ([...entry.value]..sort((a, b) {
            final int discCompare = a.discNumber.compareTo(b.discNumber);
            return discCompare != 0 ? discCompare : a.trackNumber.compareTo(b.trackNumber);
          }));
    return AlbumGroup(album: entry.key, releaseYear: ordered.first.releaseYear, tracks: ordered);
  }).toList();

  groups.sort((a, b) => b.releaseYear.compareTo(a.releaseYear));
  return groups;
}
