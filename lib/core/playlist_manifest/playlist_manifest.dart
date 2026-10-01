import 'manifest_track_ref.dart';

/// Manifeste JSON léger (métadonnées uniquement) d'une playlist — format
/// commun à l'export local, l'import Spotify, et le partage/fork (Étape 6).
class PlaylistManifest {
  const PlaylistManifest({
    required this.id,
    required this.title,
    required this.description,
    required this.version,
    required this.tags,
    required this.vibeStyle,
    required this.tracks,
    this.creatorHandle,
    this.originalCreator,
  });

  final String id;
  final String title;
  final String description;
  final int version;
  final List<String> tags;
  final String vibeStyle;
  final List<ManifestTrackRef> tracks;

  /// Auteur de CE manifeste, saisi au moment de l'export (fenêtre "Nom de
  /// l'auteur de la playlist") — sérialisé sous la clé `author` (et
  /// `creatorHandle`, nom historique relu par les versions précédentes).
  /// Sert à l'attribution "Inspiré par @X" à l'import.
  final String? creatorHandle;

  /// Renseigné si ce manifeste est déjà lui-même issu d'un fork.
  final String? originalCreator;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': creatorHandle,
        'description': description,
        'version': version,
        'tags': tags,
        'vibeStyle': vibeStyle,
        'creatorHandle': creatorHandle,
        'originalCreator': originalCreator,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      };

  /// Tolérant aux JSON produits ailleurs : seul `title` est indispensable.
  /// Sans `id`, un identifiant stable est dérivé du titre (un réimport du
  /// même fichier est alors reconnu comme une mise à jour, pas un doublon).
  factory PlaylistManifest.fromJson(Map<String, dynamic> json) {
    final String title = (json['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) throw const FormatException('Titre de playlist manquant');
    final String? author = _nonEmpty(json['author']) ?? _nonEmpty(json['creatorHandle']);

    return PlaylistManifest(
      id: _nonEmpty(json['id']) ?? 'manifest-${title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
      title: title,
      description: json['description'] as String? ?? '',
      version: json['version'] as int? ?? 1,
      tags: (json['tags'] as List<dynamic>? ?? const []).whereType<String>().toList(),
      vibeStyle: json['vibeStyle'] as String? ?? 'minimal',
      creatorHandle: author,
      originalCreator: _nonEmpty(json['originalCreator']),
      tracks: (json['tracks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ManifestTrackRef.fromJson)
          .where((t) => t.title.trim().isNotEmpty)
          .toList(),
    );
  }

  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
