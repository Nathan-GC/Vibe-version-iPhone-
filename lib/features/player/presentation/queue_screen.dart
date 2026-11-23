import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio_engine/player_controller.dart';
import '../../../core/audio_engine/queue_controller.dart';
import '../../../core/storage/database/app_database.dart';
import '../widgets/waveform_indicator.dart';

/// Hauteur fixe d'une ligne à l'échelle de texte 1 : un `ListTile` à 2 lignes
/// (titre + artistes) fait 72 dp en Material 3. La fixer permet de calculer le
/// décalage exact d'un titre sans le mesurer, même sur une file de 2 000
/// titres. Elle suit l'échelle de texte des réglages Android (voir
/// `_QueueListState._extent`) : à 72 dp fixes, un texte agrandi serait coupé.
const double kQueueItemExtent = 72;

/// Après un défilement manuel (doigt ou barre rapide), la liste ne se recale
/// plus sur le titre en cours pendant ce délai : on ne reprend pas la liste
/// sous le doigt de l'utilisateur.
const Duration kQueueManualScrollGrace = Duration(seconds: 5);

/// Durée du recalage animé quand le titre en cours change.
const Duration kQueueFollowDuration = Duration(milliseconds: 300);

/// Page 2 du swipe horizontal (Tab 2) : queue en lecture seule, dans l'ordre
/// de la source (pas de drag-and-drop), tap-to-play, équaliseur 4 barres animé
/// sur la piste en cours de lecture.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> tracks = ref.watch(queueTracksProvider);

    return SafeArea(
      child: tracks.when(
        data: (data) {
          if (data.isEmpty) return const Center(child: Text("File d'attente vide."));
          return _QueueList(tracks: data);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
    );
  }
}

/// Liste des titres. Montée seulement une fois la file résolue : son
/// contrôleur démarre ainsi directement au bon décalage (titre en cours en 2e
/// ligne), sans flash en haut de liste ni animation.
class _QueueList extends ConsumerStatefulWidget {
  const _QueueList({required this.tracks});

  final List<Track> tracks;

  @override
  ConsumerState<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends ConsumerState<_QueueList> {
  // Contrôleur explicite : partagé par la liste et sa barre de défilement,
  // sans dépendre du PrimaryScrollController, déjà pris par la page Lecteur.
  // Créé au premier layout, quand la hauteur visible (donc la fin de file)
  // est connue.
  ScrollController? _scrollController;
  Timer? _manualScrollTimer;
  bool _recentlyScrolledByUser = false;
  // Vrai pendant nos propres animations : leurs notifications de défilement ne
  // sont pas des gestes de l'utilisateur.
  bool _programmaticScroll = false;
  // Hauteur effective d'une ligne, mise à jour à chaque build.
  double _extent = kQueueItemExtent;

  /// Décalage qui met le titre d'index [index] en 2e ligne (le précédent juste
  /// au-dessus), borné à la fin de la file.
  double _offsetFor(int index, double maxExtent) => (math.max(0, index - 1) * _extent).clamp(0.0, maxExtent);

  int _currentIndex() {
    final String? id = ref.read(playerControllerProvider).currentTrack?.id;
    return id == null ? -1 : widget.tracks.indexWhere((t) => t.id == id);
  }

  @override
  void dispose() {
    _manualScrollTimer?.cancel();
    _scrollController?.dispose();
    super.dispose();
  }

  /// Notification d'un défilement qui ne vient pas de nous : doigt, ou barre
  /// de défilement rapide (qui déplace la position sans `dragDetails`).
  bool _onScroll(ScrollNotification notification) {
    if (_programmaticScroll || notification.depth != 0) return false;
    final bool userMoved = notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        (notification is UserScrollNotification && notification.direction != ScrollDirection.idle);
    if (userMoved) {
      _recentlyScrolledByUser = true;
      _manualScrollTimer?.cancel();
      _manualScrollTimer = Timer(kQueueManualScrollGrace, () => _recentlyScrolledByUser = false);
    }
    return false;
  }

  Future<void> _followCurrent() async {
    final ScrollController? controller = _scrollController;
    if (_recentlyScrolledByUser || controller == null || !controller.hasClients) return;
    final int index = _currentIndex();
    if (index < 0) return;
    final double target = _offsetFor(index, controller.position.maxScrollExtent);
    if ((target - controller.offset).abs() < 0.5) return;
    _programmaticScroll = true;
    try {
      await controller.animateTo(target, duration: kQueueFollowDuration, curve: Curves.easeOut);
    } finally {
      _programmaticScroll = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final PlayerSnapshot player = ref.watch(playerControllerProvider);
    ref.listen<String?>(
      playerControllerProvider.select((s) => s.currentTrack?.id),
      (_, __) => _followCurrent(),
    );
    final List<Track> data = widget.tracks;
    _extent = MediaQuery.textScalerOf(context).scale(kQueueItemExtent);

    return LayoutBuilder(
      builder: (context, constraints) {
        _scrollController ??= ScrollController(
          initialScrollOffset: _offsetFor(
            _currentIndex(),
            math.max(0.0, data.length * _extent - constraints.maxHeight),
          ),
        );
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
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: ListView.builder(
              controller: _scrollController,
              itemExtent: _extent,
              itemCount: data.length,
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
          ),
        );
      },
    );
  }
}
