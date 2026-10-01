import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../../../core/shared/widgets/add_to_playlist_sheet.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_repository.dart';

/// Correspondance locale (bibliothèque déjà possédée) d'un résultat en ligne
/// — utilisé par la Discographie (Profil Artiste) pour masquer le bouton "+"
/// sur les titres non téléchargés plutôt que de laisser l'utilisateur le
/// découvrir seulement après un tap infructueux (voir `addOnlineTrackToPlaylist`).
/// `autoDispose` : ces résultats ne servent qu'à l'affichage de la feuille de
/// discographie ouverte, inutile de les garder en mémoire au-delà.
final localTrackMatchProvider =
    FutureProvider.autoDispose.family<Track?, ({String title, String artist})>((ref, query) {
  return ref.watch(trackRepositoryProvider).findLocalMatch(query.title, query.artist);
});

/// Bouton "+" d'un [OnlineTrackResult] (Morceaux populaires, discographie,
/// Étape "découverte d'artiste") : l'app est locale-first et ne peut pas
/// télécharger le morceau complet depuis iTunes (seul un extrait 30s est
/// disponible) — on ne peut donc ajouter à une playlist que si ce morceau
/// est déjà possédé localement.
Future<void> addOnlineTrackToPlaylist(BuildContext context, WidgetRef ref, OnlineTrackResult track) async {
  final Track? local = await ref.read(trackRepositoryProvider).findLocalMatch(track.title, track.artist);

  if (local == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text("Pas encore dans ta bibliothèque locale — importe le fichier audio pour l'ajouter à une playlist."),
        ),
      );
    }
    return;
  }

  if (context.mounted) await AddToPlaylistSheet.show(context, local.id);
}
