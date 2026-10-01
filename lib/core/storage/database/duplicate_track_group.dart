import 'app_database.dart';

/// Groupe de morceaux strictement identiques (même Titre, même Artiste,
/// comparaison insensible à la casse) — voir [DuplicateDetectorService].
class DuplicateTrackGroup {
  const DuplicateTrackGroup({required this.title, required this.artist, required this.tracks});

  final String title;
  final String artist;
  final List<Track> tracks;
}
