import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/playlists/data/playlist_providers.dart';
import '../../../features/playlists/domain/playlist_editor_entry.dart';
import '../../audio_engine/player_controller.dart';
import '../../storage/database/app_database.dart';
import '../../theme/design_system/app_spacing.dart';
import '../../theme/design_system/vibe_design_system.dart';
import 'playlist_cover_image.dart';

// Playlists dont le lancement est en cours : un double tap rapide (fréquent
// maintenant que l'appui simple lance directement la lecture) ne doit pas
// relancer deux fois la même playlist depuis le début.
final Set<String> _launchingPlaylistIds = {};

/// Lecture immédiate d'une playlist (appui simple sur une carte ou une ligne
/// de playlist, voir la convention de gestes de [PlaylistCard]) puis bascule
/// sur le Lecteur. Les titres grisés (import JSON sans morceau local) sont
/// exclus par `fetchOrderedTracks` : le lecteur les saute. Rien de lisible
/// (playlist vide ou entièrement grisée) : un message l'indique et
/// rappelle que l'appui long ouvre l'éditeur — plutôt qu'un tap sans aucun
/// effet visible, qui ressemblerait à un geste non pris en compte.
Future<void> playPlaylistAndNavigate(BuildContext context, WidgetRef ref, Playlist playlist) async {
  if (!_launchingPlaylistIds.add(playlist.id)) return;
  try {
    final List<Track> tracks = await ref.read(playlistRepositoryProvider).fetchOrderedTracks(playlist.id);
    if (tracks.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          // Vide, ou uniquement des titres importés introuvables (grisés).
          SnackBar(content: Text('"${playlist.title}" n\'a aucun titre lisible — appui long pour l\'éditer.')),
        );
      }
      return;
    }
    await ref.read(playerControllerProvider.notifier).playPlaylist(playlist.id, tracks);
    if (context.mounted) context.go('/player');
  } finally {
    _launchingPlaylistIds.remove(playlist.id);
  }
}

/// Carte verticale d'une playlist (Design System, charte Spotify) : pochette
/// carrée en haut, titre en gras et sous-titre gris en dessous. Utilisée
/// aussi bien dans les carrousels horizontaux (Mon espace, Découverte) qu'en
/// grille.
///
/// Convention de gestes commune à toute l'app (retest QA 61b5cf1) :
///  - appui simple, n'importe où sur la carte (pochette, titre,
///    sous-titre) = LECTURE immédiate ([onTap], en pratique
///    [playPlaylistAndNavigate]) ;
///  - appui long = SEUL accès à la vue détaillée ([onLongPress] : éditeur de
///    playlist, fiche artiste, feuille d'actions d'un morceau).
/// Exception : les listes réordonnables (file d'attente, éditeur de
/// playlist) où l'appui long reste réservé au glisser-déposer.
///
/// Une seule zone tactile (un seul InkWell) : l'ancienne distinction
/// pochette = lecture / titre = édition (Section 3.3) est abandonnée.
class PlaylistCard extends StatelessWidget {
  const PlaylistCard(
      {super.key, required this.playlist, required this.onTap, required this.onLongPress, this.width = 152});

  final Playlist playlist;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.card)),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: PlaylistCoverImage(playlist: playlist),
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            _PlaylistSubtitle(playlist: playlist),
          ],
        ),
      ),
    );
  }
}

class _PlaylistSubtitle extends ConsumerWidget {
  const _PlaylistSubtitle({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<PlaylistEditorEntry>> entries = ref.watch(playlistEditorEntriesProvider(playlist.id));
    final List<PlaylistEditorEntry> all = entries.value ?? const [];
    // Morceaux lisibles d'un côté, titres importés introuvables (grisés) de
    // l'autre : ces derniers ne sont jamais joués.
    final int missing = all.where((e) => e.isMissing).length;
    final int count = all.length - missing;
    final String by = playlist.originalCreator == null ? 'Toi' : '@${playlist.originalCreator}';

    return Text(
      'Par $by • $count morceau${count > 1 ? 'x' : ''}${missing > 0 ? ' · $missing grisé${missing > 1 ? 's' : ''}' : ''}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
