import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio_engine/preview_player_controller.dart';
import '../../networking/metadata_api_client/online_track_result.dart';

/// Carte pour un morceau public non téléchargé : cover, infos, contrôle de
/// preview 20-30s (streaming direct via `previewUrl`) et action d'ajout.
class OnlineTrackCard extends ConsumerWidget {
  const OnlineTrackCard({super.key, required this.track, this.onAdd});

  final OnlineTrackResult track;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? activePreviewUrl = ref.watch(previewPlayerControllerProvider);
    final bool isPlayingThis = activePreviewUrl != null && activePreviewUrl == track.previewUrl;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: track.coverArtUrl != null
              ? Image.network(
                  track.coverArtUrl!,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  semanticLabel: 'Pochette de ${track.title}',
                )
              : Container(
                  width: 48,
                  height: 48,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.music_note),
                ),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (track.isExplicit) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outline,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  'E',
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.surface),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          [track.artist, if (track.album != null) track.album, if (track.releaseYear != null) '${track.releaseYear}']
              .join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (track.previewUrl != null)
              IconButton(
                icon: Icon(isPlayingThis ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                tooltip: isPlayingThis ? 'Arrêter la preview' : 'Écouter un extrait (20-30s)',
                onPressed: () => ref.read(previewPlayerControllerProvider.notifier).togglePreview(track.previewUrl!),
              ),
            if (onAdd != null)
              IconButton(
                icon: const Icon(Icons.add_circle_outline, semanticLabel: 'Ajouter à une playlist'),
                onPressed: onAdd,
              ),
          ],
        ),
      ),
    );
  }
}
