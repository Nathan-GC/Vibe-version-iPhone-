import '../../../core/storage/database/app_database.dart';

/// Une ligne de playlist dans l'ordre d'affichage : soit un morceau de la
/// bibliothèque ([track]), soit un titre importé encore introuvable
/// localement ([missing], affiché grisé et jamais lu — voir
/// [PlaylistMissingTracks]). Les deux partagent la même numérotation de
/// [position].
///
/// [isPendingPlacement] : morceau ajouté mais jamais réordonné manuellement
/// dans l'éditeur (contour ambre tant que non commité) — toujours `false`
/// pour un titre grisé.
class PlaylistEditorEntry {
  const PlaylistEditorEntry({required Track this.track, required this.isPendingPlacement, required this.position})
      : missing = null;

  PlaylistEditorEntry.missing(PlaylistMissingTrack this.missing)
      : track = null,
        isPendingPlacement = false,
        position = missing.position;

  final Track? track;
  final PlaylistMissingTrack? missing;
  final bool isPendingPlacement;
  final int position;

  bool get isMissing => missing != null;

  /// Identifiant stable dans la liste (clé de widget, réordonnancement).
  String get key => track != null ? 'track:${track!.id}' : 'missing:${missing!.id}';

  String get title => track?.title ?? missing!.title;

  String get artistLabel => track != null ? track!.artists.join(', ') : missing!.artist;
}
