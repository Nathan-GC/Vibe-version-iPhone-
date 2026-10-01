import '../../../core/playlist_manifest/manifest_track_ref.dart';

/// Résultat de comparaison entre un manifeste JSON importé et la playlist
/// locale (Étape 6). Les entrées sont recoupées via `sanitizedKey`.
class DiffResult {
  const DiffResult({
    required this.localVersion,
    required this.incomingVersion,
    required this.added,
    required this.removed,
  });

  final int localVersion;
  final int incomingVersion;
  final List<ManifestTrackRef> added;
  final List<ManifestTrackRef> removed;

  bool get hasChanges => added.isNotEmpty || removed.isNotEmpty;
}
