import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/audio_engine/queue_controller.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/features/player/presentation/queue_screen.dart';

class _IdlePlayerController extends PlayerController {
  @override
  PlayerSnapshot build() => const PlayerSnapshot(status: PlaybackStatus.idle);
}

Track _track(int i) => Track(
      id: 't$i',
      title: 'Track $i',
      album: '',
      releaseYear: 0,
      artists: const ['A'],
      durationSeconds: 180,
      bpm: 120,
      trimStartMs: 0,
      trimEndMs: 0,
      filePath: '/music/t$i.mp3',
      coverArtPath: '',
      tags: const [],
      createdAt: DateTime(2026),
      requiresUserReview: false,
      playCount: 0,
      lastModifiedEpochMs: 0,
      trackNumber: 0,
      discNumber: 0,
      trackCount: 0,
      enrichmentAttempts: 0,
      enrichmentStatus: EnrichmentStatus.pending,
    );

void main() {
  testWidgets('dragging the always-visible scrollbar thumb jumps through a long queue (Lot 3.1)', (tester) async {
    final List<Track> tracks = [for (int i = 0; i < 500; i++) _track(i)];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        queueTracksProvider.overrideWith((ref) async => tracks),
        playerControllerProvider.overrideWith(_IdlePlayerController.new),
      ],
      child: const MaterialApp(home: Scaffold(body: QueueScreen())),
    ));
    await tester.pumpAndSettle();

    final RawScrollbar scrollbar = tester.widget(find.byType(RawScrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.interactive, isTrue);
    expect(find.text('Track 0'), findsOneWidget);

    // Poignée en haut à droite de la liste, glissée jusqu'en bas.
    final Rect list = tester.getRect(find.byType(RawScrollbar));
    await tester.dragFrom(Offset(list.right - 4, list.top + 20), Offset(0, list.height));
    await tester.pumpAndSettle();

    expect(find.text('Track 0'), findsNothing);
    expect(find.text('Track 499'), findsOneWidget);
  });

  testWidgets('the queue is read-only: a long-press drag never reorders it', (tester) async {
    final List<Track> tracks = [for (int i = 0; i < 5; i++) _track(i)];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        queueTracksProvider.overrideWith((ref) async => tracks),
        playerControllerProvider.overrideWith(_IdlePlayerController.new),
      ],
      child: const MaterialApp(home: Scaffold(body: QueueScreen())),
    ));
    await tester.pumpAndSettle();

    final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(QueueScreen)));
    // Écouteur explicite : la queue est auto-dispose et rien ne l'observe ici
    // (queueTracksProvider est surchargé), son état repartirait sinon à vide.
    final ProviderSubscription<List<String>> queue = container.listen(queueControllerProvider, (_, __) {});
    addTearDown(queue.close);
    final List<String> order = [for (final Track t in tracks) t.id];
    container.read(queueControllerProvider.notifier).restore(order);
    await tester.pumpAndSettle();

    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);

    // Appui long puis glissement vers le bas sur la première ligne.
    final TestGesture gesture = await tester.startGesture(tester.getCenter(find.text('Track 0')));
    await tester.pump(const Duration(seconds: 1));
    await gesture.moveBy(const Offset(0, 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(container.read(queueControllerProvider), order);
  });
}
