import '../../../core/playlist_manifest/manifest_track_ref.dart';

/// Résultat de comparaison entre un manifeste JSON importé et la playlist
/// locale (Étape 6). Les entrées sont recoupées via `sanitizedKey`.
class DiffResult {
  const DiffResult({
    required this.localVersion,
    required this.incomingVersion,
    required this.added,
    required this.removed,
    required this.contentChanged,
    required this.orderChanged,
  });

  final int localVersion;
  final int incomingVersion;
  final List<ManifestTrackRef> added;
  final List<ManifestTrackRef> removed;

  /// La liste ORDONNÉE des titres (clé tolérante, 1re occurrence) diffère
  /// entre la playlist locale et le manifeste : ajouts, retraits ou nouvel
  /// ordre. Permet de proposer une mise à jour même à version égale.
  final bool contentChanged;

  /// L'ordre relatif des titres communs aux deux listes diffère.
  final bool orderChanged;

  /// Ajouts ou retraits seulement (un simple nouvel ordre n'en fait pas partie).
  bool get hasChanges => added.isNotEmpty || removed.isNotEmpty;
}
