import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../storage/database/app_database.dart';
import '../../storage/database/track_repository.dart';
import '../../theme/vibe_engine/vibe_engine.dart';
import '../../../features/playlists/data/playlist_providers.dart';
import '../../../features/playlists/data/playlist_track_repository.dart';

/// Tronque un titre à [maxLength] caractères, suivi de « … » s'il est plus long.
/// Compté en caractères visibles (`characters`) : couper au milieu d'un emoji
/// laissait un « � » dans le snackbar.
String truncateTitle(String title, {int maxLength = 30}) {
  final Characters chars = title.characters;
  return chars.length <= maxLength ? title : '${chars.take(maxLength)}…';
}

/// Modale de sélection rapide, réutilisée partout où un morceau peut être
/// ajouté à une playlist sans naviguer vers un écran secondaire (Player,
/// Recherche, Bibliothèque, éditeur de playlist).
class AddToPlaylistSheet extends ConsumerWidget {
  const AddToPlaylistSheet({super.key, required this.trackId});

  final String trackId;

  static Future<void> show(BuildContext context, String trackId) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => AddToPlaylistSheet(trackId: trackId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);

    return SafeArea(
      child: playlists.when(
        data: (data) {
          if (data.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Aucune playlist — crée-en une depuis "Mon espace".'),
            );
          }
          return ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text('Ajouter à...', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ...data.map(
                (playlist) => ListTile(
                  leading: CircleAvatar(backgroundColor: playlist.vibeStyle.accentColor, radius: 10),
                  title: Text(playlist.title),
                  onTap: () async {
                    // Tout est capturé avant l'await : la feuille est fermée
                    // ensuite, le snackbar s'affiche sur l'écran en dessous.
                    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
                    final NavigatorState navigator = Navigator.of(context);
                    final Color errorColor = Theme.of(context).colorScheme.error;
                    final PlaylistTrackRepository playlistTracks = ref.read(playlistTrackRepositoryProvider);
                    final TrackRepository tracks = ref.read(trackRepositoryProvider);

                    final AddTrackResult result = await playlistTracks.addTrack(playlist.id, trackId);
                    final String title = (await tracks.findById(trackId))?.title ?? '';
                    navigator.pop();

                    final SnackBar snackBar = switch (result) {
                      AddTrackResult.added => SnackBar(
                          content: Text('"${truncateTitle(title)}" a été ajouté à la playlist "${playlist.title}"'),
                          action: SnackBarAction(
                            label: 'Annuler',
                            onPressed: () => playlistTracks.removeTrack(playlist.id, trackId),
                          ),
                          // Un SnackBar à action est `persist` par défaut : sans
                          // ceci il ne se ferme jamais et l'alerte suivante
                          // (doublon) resterait invisible en file derrière.
                          persist: false,
                          duration: const Duration(seconds: 4),
                        ),
                      AddTrackResult.alreadyPresent => SnackBar(
                          content: const Text('Ce titre est déjà présent dans la playlist'),
                          backgroundColor: errorColor,
                        ),
                      AddTrackResult.notInLibrary => SnackBar(
                          content: const Text("Ce titre n'est plus dans la bibliothèque."),
                          backgroundColor: errorColor,
                        ),
                    };
                    messenger
                      ..hideCurrentSnackBar()
                      ..showSnackBar(snackBar);
                  },
                ),
              ),
            ],
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : $error')),
      ),
    );
  }
}
