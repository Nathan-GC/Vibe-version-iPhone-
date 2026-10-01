import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/shared/widgets/online_track_card.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/theme/vibe_engine/active_vibe_provider.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../data/artist_providers.dart';
import '../domain/album_group.dart';
import 'online_track_actions.dart';

/// Morceaux d'un album de la discographie en ligne (tap sur une vignette
/// d'album, Profil Artiste). L'app étant locale-first, il n'existe pas de
/// mécanisme légal pour télécharger le morceau complet depuis iTunes — cette
/// vue permet d'écouter un extrait 30s et d'ajouter à une playlist les
/// morceaux déjà présents dans la bibliothèque locale (voir
/// online_track_actions.dart), pas d'"importer" l'album au sens strict.
class AlbumTracksSheet extends ConsumerWidget {
  const AlbumTracksSheet({super.key, required this.album});

  final AlbumGroup album;

  static Future<void> show(BuildContext context, AlbumGroup album) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // iOS : tirée à pleine hauteur, la feuille passerait sous l'encoche/la
      // Dynamic Island — bornée à la zone sûre (Android : inchangé).
      useSafeArea: AppPlatform.isIOS,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scrollController) => AlbumTracksSheet(album: album),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int? collectionId = album.collectionId;
    final VibeVisual vibe = ref.watch(activeVibeProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                if (album.artworkUrl != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      album.artworkUrl!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      semanticLabel: "Pochette de l'album ${album.album}",
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.album,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: vibe.accentColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (album.releaseYear > 0)
                        Text('${album.releaseYear}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: collectionId == null
                ? const Padding(padding: EdgeInsets.all(24), child: Text('Album incomplet.'))
                : Consumer(
                    builder: (context, ref, _) {
                      final tracks = ref.watch(albumTracksProvider(collectionId));
                      return tracks.when(
                        data: (data) => data.isEmpty
                            ? const Padding(padding: EdgeInsets.all(24), child: Text('Aucun morceau trouvé.'))
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: data.length,
                                itemBuilder: (context, index) => _DiscographyTrackCard(track: data[index]),
                              ),
                        loading: () => Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator(color: vibe.accentColor)),
                        ),
                        error: (error, _) => Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : $error')),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Titre de la discographie en ligne : le bouton "+" ne s'affiche que si le
/// morceau est déjà présent dans la bibliothèque locale — l'app est
/// locale-first et ne peut télécharger que 30s d'extrait, ajouter un titre
/// non possédé à une playlist n'aurait donc aucun sens (voir
/// online_track_actions.dart).
class _DiscographyTrackCard extends ConsumerWidget {
  const _DiscographyTrackCard({required this.track});

  final OnlineTrackResult track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Track?> localMatch =
        ref.watch(localTrackMatchProvider((title: track.title, artist: track.artist)));
    final bool isLocal = localMatch.value != null;

    return OnlineTrackCard(
      track: track,
      onAdd: isLocal ? () => addOnlineTrackToPlaylist(context, ref, track) : null,
    );
  }
}
