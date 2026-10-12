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
    final Rect list = tester.getRect(find.byType(ReorderableListView));
    await tester.dragFrom(Offset(list.right - 4, list.top + 20), Offset(0, list.height));
    await tester.pumpAndSettle();

    expect(find.text('Track 0'), findsNothing);
    expect(find.text('Track 499'), findsOneWidget);
  });
}
