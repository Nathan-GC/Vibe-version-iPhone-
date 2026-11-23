import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/audio_engine/queue_controller.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/features/player/presentation/queue_screen.dart';

/// Contrôleur dont le titre en cours se change depuis le test.
class _CurrentPlayerController extends PlayerController {
  static Track? initial;

  @override
  PlayerSnapshot build() => PlayerSnapshot(status: PlaybackStatus.paused, currentTrack: initial);

  void setCurrent(Track track) => state = PlayerSnapshot(status: PlaybackStatus.paused, currentTrack: track);
}

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
      identityLocked: false,
      overwriteOnEnrich: false,
    );

void main() {
  final List<Track> tracks = [for (int i = 0; i < 200; i++) _track(i)];

  Future<ScrollController> pumpQueue(WidgetTester tester, int? current) async {
    _CurrentPlayerController.initial = current == null ? null : tracks[current];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        queueTracksProvider.overrideWith((ref) async => tracks),
        playerControllerProvider.overrideWith(_CurrentPlayerController.new),
      ],
      child: const MaterialApp(home: Scaffold(body: QueueScreen())),
    ));
    await tester.pump(); // résout la file : pas d'animation à attendre
    await tester.pump();
    return tester.widget<ListView>(find.byType(ListView)).controller!;
  }

  void setCurrent(WidgetTester tester, int i) {
    final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(QueueScreen)));
    (c.read(playerControllerProvider.notifier) as _CurrentPlayerController).setCurrent(tracks[i]);
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('arrival: the current track is the 2nd visible row, positioned at once', (tester) async {
    final ScrollController c = await pumpQueue(tester, 100);
    expect(c.offset, 99 * kQueueItemExtent);
    // Ligne précédente = 1re ligne visible, le titre en cours juste dessous.
    expect(tester.getTopLeft(find.text('Track 99')).dy, lessThan(tester.getTopLeft(find.text('Track 100')).dy));
    expect(find.text('Track 98'), findsNothing);
    expect(tester.getTopLeft(find.text('Track 99')).dy, lessThan(kQueueItemExtent));
    await teardown(tester);
  });

  testWidgets('first track of the queue: list stays at the top', (tester) async {
    final ScrollController c = await pumpQueue(tester, 0);
    expect(c.offset, 0);
    await teardown(tester);
  });

  testWidgets('no current track: list stays at the top', (tester) async {
    final ScrollController c = await pumpQueue(tester, null);
    expect(c.offset, 0);
    await teardown(tester);
  });

  testWidgets('last track of the queue: offset is capped at the end of the list', (tester) async {
    final ScrollController c = await pumpQueue(tester, 199);
    expect(c.offset, c.position.maxScrollExtent);
    expect(c.offset, lessThan(198 * kQueueItemExtent));
    expect(find.text('Track 199'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('current track change re-centres the list on the new track', (tester) async {
    final ScrollController c = await pumpQueue(tester, 100);
    setCurrent(tester, 101);
    await tester.pumpAndSettle();
    expect(c.offset, 100 * kQueueItemExtent);
    await teardown(tester);
  });

  testWidgets('current track change right after a manual scroll does not move the list', (tester) async {
    final ScrollController c = await pumpQueue(tester, 100);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final double manual = c.offset;
    expect(manual, isNot(99 * kQueueItemExtent));

    setCurrent(tester, 101);
    await tester.pumpAndSettle();
    expect(c.offset, manual);
    await teardown(tester);
  });

  testWidgets('after the grace period the list follows the current track again', (tester) async {
    final ScrollController c = await pumpQueue(tester, 100);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.pump(kQueueManualScrollGrace + const Duration(seconds: 1));

    setCurrent(tester, 101);
    await tester.pumpAndSettle();
    expect(c.offset, 100 * kQueueItemExtent);
    await teardown(tester);
  });

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
