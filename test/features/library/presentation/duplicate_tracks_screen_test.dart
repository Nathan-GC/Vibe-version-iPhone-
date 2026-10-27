import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/preview_player_controller.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/duplicate_track_group.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';
import 'package:playlist_app/features/library/presentation/duplicate_tracks_screen.dart';

void main() {
  Track track(String id, String path, int seconds) => Track(
        id: id,
        title: 'Nightcall',
        album: '',
        artists: const ['Kavinsky'],
        durationSeconds: seconds,
        filePath: path,
        coverArtPath: '',
        releaseYear: 0,
        tags: const [],
        bpm: 120,
        playCount: 0,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
        createdAt: DateTime(2026),
        trackNumber: 0,
        discNumber: 0,
        trackCount: 0,
        enrichmentAttempts: 0,
        enrichmentStatus: EnrichmentStatus.pending,
        lastModifiedEpochMs: 0,
      );

  testWidgets('each version shows its duration (mm:ss) next to its file path', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        previewPlayerControllerProvider.overrideWithValue(null),
        duplicateTrackGroupsProvider.overrideWith((ref) => Stream.value([
              DuplicateTrackGroup(
                title: 'Nightcall',
                artist: 'Kavinsky',
                tracks: [
                  track('n', '/music/Nightcall (Drive OST).mp3', 257),
                  track('n~2', '/music/Nightcall.mp3', 179)
                ],
              ),
            ])),
      ],
      child: const MaterialApp(home: DuplicateTracksScreen()),
    ));
    await tester.pump();

    expect(find.textContaining('4:17 · /music/Nightcall (Drive OST).mp3', findRichText: true), findsOneWidget);
    expect(find.textContaining('2:59 · /music/Nightcall.mp3', findRichText: true), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Durée 2 minutes 59 secondes, fichier /music/Nightcall.mp3')), findsOneWidget);
    semantics.dispose();
  });
}
