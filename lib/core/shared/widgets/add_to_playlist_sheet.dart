import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../storage/database/app_database.dart';
import '../../theme/vibe_engine/vibe_engine.dart';
import '../../../features/playlists/data/playlist_providers.dart';

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
                    await ref.read(playlistTrackRepositoryProvider).addTrack(playlist.id, trackId);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('Ajouté à "${playlist.title}"')));
                    }
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
