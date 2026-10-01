import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/vibe_engine/vibe_haptic_service.dart';
import '../../playlists/data/playlist_providers.dart';
import '../../playlists/data/playlist_repository.dart';

/// Ajout/retrait instantané à la playlist "Titres likés" (Étape 3) — la
/// playlist est créée paresseusement au premier "J'aime" (voir
/// PlaylistRepository.ensureLikedPlaylist).
class LikeButton extends ConsumerWidget {
  const LikeButton({super.key, required this.trackId, required this.color});

  final String trackId;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isLiked = ref.watch(isTrackLikedProvider(trackId)).value ?? false;

    return IconButton(
      iconSize: 32,
      icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border, color: color),
      tooltip: isLiked ? 'Retirer des Titres likés' : 'Ajouter aux Titres likés',
      onPressed: () async {
        VibeHapticService.trigger(context, VibeInteraction.like);
        final playlistTrackRepository = ref.read(playlistTrackRepositoryProvider);
        if (isLiked) {
          await playlistTrackRepository.removeTrack(kLikedPlaylistId, trackId);
        } else {
          await ref.read(playlistRepositoryProvider).ensureLikedPlaylist();
          await playlistTrackRepository.addTrack(kLikedPlaylistId, trackId);
        }
      },
    );
  }
}
