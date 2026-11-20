/// Un artiste proposé par la feuille "Ajouter par artiste" d'une playlist,
/// avec de quoi décider s'il vaut la peine de l'afficher : [totalTracks]
/// (bibliothèque entière, featurings compris) et [missingTracks] (ceux qui ne
/// sont pas encore dans la playlist). Les deux comptent exactement les
/// morceaux que l'ajout insérerait (voir DriftArtistRepository).
class PlaylistArtistCandidate {
  const PlaylistArtistCandidate({required this.artistName, required this.totalTracks, required this.missingTracks});

  /// Nom canonique, identique à celui de `fetchAllArtistNames`.
  final String artistName;
  final int totalTracks;
  final int missingTracks;
}
