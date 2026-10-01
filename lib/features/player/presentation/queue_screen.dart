import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio_engine/player_controller.dart';
import '../../../core/audio_engine/queue_controller.dart';
import '../../../core/storage/database/app_database.dart';
import '../widgets/waveform_indicator.dart';

/// Page 2 du swipe horizontal (Tab 2) : queue réordonnable par drag-and-drop,
/// tap-to-play, équaliseur 4 barres animé sur la piste en cours de lecture.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> tracks = ref.watch(queueTracksProvider);
    final PlayerSnapshot player = ref.watch(playerControllerProvider);

    return SafeArea(
      child: tracks.when(
        data: (data) {
          if (data.isEmpty) return const Center(child: Text("File d'attente vide."));
          return ReorderableListView.builder(
            itemCount: data.length,
            onReorderItem: (fromIndex, toIndex) =>
                ref.read(queueControllerProvider.notifier).reorder(fromIndex, toIndex),
            itemBuilder: (context, index) {
              final Track track = data[index];
              final bool isCurrent = player.currentTrack?.id == track.id;
              final bool isPlayingThis = isCurrent && player.status == PlaybackStatus.playing;

              return ListTile(
                key: ValueKey(track.id),
                selected: isCurrent,
                leading: SizedBox(
                  width: 24,
                  child: WaveformIndicator(isPlaying: isPlayingThis),
                ),
                title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(track.artists.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => ref.read(playerControllerProvider.notifier).playTrackAt(index),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
    );
  }
}
