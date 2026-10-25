import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/audio_engine/queue_controller.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/theme/global_theme/global_theme.dart';
import 'package:playlist_app/core/theme/vibe_engine/active_vibe_provider.dart';
import 'package:playlist_app/core/theme/vibe_engine/playlist_vibe_resolver.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/playlists/data/playlist_providers.dart';
import 'package:playlist_app/features/player/presentation/master_player_screen.dart';
import 'package:playlist_app/features/player/presentation/queue_screen.dart';
import 'package:playlist_app/features/player/widgets/progress_slider.dart';

class _PlayingPlayerController extends PlayerController {
  @override
  PlayerSnapshot build() => const PlayerSnapshot(status: PlaybackStatus.paused, currentPlaylistId: 'p1');

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();
}

Playlist _playlist({required String accentHex}) => Playlist(
      id: 'p1',
      title: 'Ma playlist',
      description: '',
      version: 1,
      tags: const [],
      vibeStyle: VibePreset.custom,
      bgColors: const ['FF101020', 'FF202040'],
      customBackgroundImagePath: '',
      customAccentColor: accentHex,
      coverImagePath: '',
      createdAt: DateTime(2026),
      customEffect: VibeCustomEffect.animatedGradient,
      customBackgroundVideoPath: '',
      showCoverImage: false,
    );

void main() {
  testWidgets('the player and its queue wear the playlist Vibe while the rest of the app keeps the identity', (
    tester,
  ) async {
    final Playlist playlist = _playlist(accentHex: 'FFFF0000');
    const Color identityAccent = Color(0xFF1DB954);
    final ThemeData identity = applyVibe(buildLightTheme(seedColor: identityAccent), defaultVibeFor(identityAccent));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        playerControllerProvider.overrideWith(_PlayingPlayerController.new),
        playlistByIdProvider.overrideWith((ref, id) => Stream.value(playlist)),
        playlistsProvider.overrideWith((ref) => Stream.value([playlist])),
        queueTracksProvider.overrideWith((ref) async => const <Track>[]),
      ],
      child: MaterialApp(theme: identity, home: const MasterPlayerScreen()),
    ));
    await tester.pump();

    final Color vibeAccent = playlist.resolvedVibe.accentColor;
    final ColorScheme expected = ColorScheme.fromSeed(seedColor: vibeAccent);

    // Page Lecteur : ses widgets Material reçoivent l'accent de la Vibe...
    final ThemeData playerTheme = Theme.of(tester.element(find.byType(ProgressSlider)));
    expect(playerTheme.colorScheme.primary, expected.primary);
    // ... qui n'est pas celui de l'identité de l'app.
    expect(playerTheme.colorScheme.primary, isNot(identity.colorScheme.primary));
    // Le thème au-dessus du Lecteur (le reste de l'app) reste l'identité.
    expect(Theme.of(tester.element(find.byType(MasterPlayerScreen))).colorScheme.primary, identity.colorScheme.primary);

    // Page file d'attente (swipe) : même Vibe.
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pump(const Duration(seconds: 1));
    expect(Theme.of(tester.element(find.byType(QueueScreen))).colorScheme.primary, expected.primary);
  });
}
