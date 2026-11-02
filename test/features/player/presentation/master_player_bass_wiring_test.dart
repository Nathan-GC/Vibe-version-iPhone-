import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_analysis/track_audio_analysis_provider.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/audio_engine/queue_controller.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/playlists/data/playlist_providers.dart';
import 'package:playlist_app/features/player/presentation/master_player_screen.dart';
import 'package:playlist_app/features/player/widgets/fluid_background.dart';

final Track _track = Track(
  id: 't1',
  title: 'Titre',
  album: '',
  releaseYear: 0,
  artists: const ['A'],
  durationSeconds: 180,
  bpm: 120,
  trimStartMs: 0,
  trimEndMs: 0,
  filePath: '/m/t1.mp3',
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

class _PausedPlayerController extends PlayerController {
  @override
  PlayerSnapshot build() =>
      PlayerSnapshot(status: PlaybackStatus.paused, currentTrack: _track, currentPlaylistId: 'p1');

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();
}

Playlist _playlist(VibePreset preset) => Playlist(
      id: 'p1',
      title: 'Ma playlist',
      description: '',
      version: 1,
      tags: const [],
      vibeStyle: preset,
      bgColors: const [],
      customBackgroundImagePath: '',
      windowBackgroundImagePath: '',
      customAccentColor: '',
      coverImagePath: '',
      createdAt: DateTime(2026),
      customEffect: VibeCustomEffect.animatedGradient,
      customBackgroundVideoPath: '',
      showCoverImage: false,
    );

void main() {
  /// Affiche le Lecteur sous la Vibe [preset] et renvoie les ids de morceau dont
  /// l'analyse a été demandée, avec le contrôleur de tempo de l'écran.
  Future<({List<String> requested, FluidBackground background})> pumpPlayer(
    WidgetTester tester,
    VibePreset preset,
  ) async {
    final Playlist playlist = _playlist(preset);
    final List<String> requested = [];
    // Le bouton "J'aime" ouvre la base dès qu'un morceau est affiché.
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        playerControllerProvider.overrideWith(_PausedPlayerController.new),
        playlistByIdProvider.overrideWith((ref, id) => Stream.value(playlist)),
        playlistsProvider.overrideWith((ref) => Stream.value([playlist])),
        queueTracksProvider.overrideWith((ref) async => const <Track>[]),
        trackAudioAnalysisProvider.overrideWith((ref, id) async {
          requested.add(id);
          return (envelope: Uint8List.fromList([255, 255]), estimatedBpm: 140);
        }),
      ],
      child: const MaterialApp(home: MasterPlayerScreen()),
    ));
    await tester.pump();
    await tester.pump();
    return (requested: requested, background: tester.widget<FluidBackground>(find.byType(FluidBackground)));
  }

  testWidgets('Behind the window analyzes the current track and feeds the tempo controller', (tester) async {
    final result = await pumpPlayer(tester, VibePreset.neon);

    expect(result.requested, ['t1']);
    // Le tag vaut 120 (défaut) : l'estimation de l'analyse le remplace.
    expect(result.background.tempoController.bpm, 140);
    // Enveloppe reçue : le niveau des basses n'est plus nul.
    expect(result.background.tempoController.bassLevel, isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('any other Vibe never starts an analysis and keeps the tag BPM, without bass level', (tester) async {
    final result = await pumpPlayer(tester, VibePreset.minimal);

    expect(result.requested, isEmpty);
    expect(result.background.tempoController.bpm, 120);
    expect(result.background.tempoController.bassLevel, isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
