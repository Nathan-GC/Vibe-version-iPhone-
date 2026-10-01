import '../identity/track_key.dart';

/// Référence légère d'un morceau dans un manifeste de playlist partageable
/// (métadonnées seules — jamais de fichier audio, voir PlaylistManifest).
class ManifestTrackRef {
  const ManifestTrackRef({required this.title, required this.artist, this.album});

  final String title;
  final String artist;
  final String? album;

  /// Même schéma de clé que celui généré au scan (core/identity/track_key.dart) —
  /// permet de faire correspondre une entrée de manifeste à un `tracks.id` local.
  String get sanitizedKey => buildSanitizedKey(title: title, album: album, primaryArtist: artist);

  Map<String, dynamic> toJson() => {'title': title, 'artist': artist, 'album': album};

  factory ManifestTrackRef.fromJson(Map<String, dynamic> json) {
    final String? album = (json['album'] as String?)?.trim();
    return ManifestTrackRef(
      title: (json['title'] as String?)?.trim() ?? '',
      artist: (json['artist'] as String?)?.trim() ?? '',
      album: (album == null || album.isEmpty) ? null : album,
    );
  }
}
