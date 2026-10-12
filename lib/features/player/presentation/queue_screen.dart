import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio_engine/player_controller.dart';
import '../../../core/audio_engine/queue_controller.dart';
import '../../../core/storage/database/app_database.dart';
import '../widgets/waveform_indicator.dart';

/// Page 2 du swipe horizontal (Tab 2) : queue réordonnable par drag-and-drop,
/// tap-to-play, équaliseur 4 barres animé sur la piste en cours de lecture.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  // Contrôleur explicite : partagé par la liste et sa barre de défilement,
  // sans dépendre du PrimaryScrollController, déjà pris par la page Lecteur.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Track>> tracks = ref.watch(queueTracksProvider);
    final PlayerSnapshot player = ref.watch(playerControllerProvider);

    return SafeArea(
      child: tracks.when(
        data: (data) {
          if (data.isEmpty) return const Center(child: Text("File d'attente vide."));
          // Lot 3.1 : barre de défilement rapide, toujours visible et
          // déplaçable au doigt pour sauter dans une longue file d'attente.
          // Poignée d'au moins 48 dp (cible tactile accessible) : la
          // Scrollbar Material la réduit à 18 px sur une file de 2 000 titres.
          return RawScrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            interactive: true,
            thickness: 8,
            minThumbLength: 48,
            radius: const Radius.circular(4),
            thumbColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            child: ReorderableListView.builder(
              scrollController: _scrollController,
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
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
    );
  }
}
