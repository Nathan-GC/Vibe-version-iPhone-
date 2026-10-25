import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/app/app.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/purge/local_notification_service.dart';
import 'package:playlist_app/core/purge/purge_providers.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/theme/global_theme/global_theme.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/playlists/data/playlist_providers.dart';
import 'package:playlist_app/features/settings/presentation/legal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotifications implements LocalNotificationService {
  @override
  Future<void> initialize({void Function()? onNotificationTap, bool requestIOSPermission = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Lecteur factice dont la playlist en cours se change depuis le test.
class _SwitchablePlayerController extends PlayerController {
  @override
  PlayerSnapshot build() => const PlayerSnapshot(status: PlaybackStatus.idle);

  void playlist(String? id) => state = PlayerSnapshot(status: PlaybackStatus.idle, currentPlaylistId: id);
}

Playlist _playlist(String id, {required VibePreset preset, String accentHex = '', List<String> bgColors = const []}) =>
    Playlist(
      id: id,
      title: id,
      description: '',
      version: 1,
      tags: const [],
      vibeStyle: preset,
      bgColors: bgColors,
      customBackgroundImagePath: '',
      customAccentColor: accentHex,
      coverImagePath: '',
      createdAt: DateTime(2026),
      customEffect: VibeCustomEffect.fluid,
      customBackgroundVideoPath: '',
      showCoverImage: true,
    );

void main() {
  late _SwitchablePlayerController player;

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding.full_scan_completed': true,
      'legal.accepted_version': LegalScreen.lastUpdated,
    });
    player = _SwitchablePlayerController();
    final Map<String, Playlist> playlists = {
      'red': _playlist('red', preset: VibePreset.custom, accentHex: 'FFFF0000', bgColors: ['FF300000', 'FF600000']),
      'preset': _playlist('preset', preset: VibePreset.values.firstWhere((p) => p != VibePreset.custom)),
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [
        localNotificationServiceProvider.overrideWithValue(_FakeNotifications()),
        purgeCheckOnLaunchProvider.overrideWith((ref) async {}),
        playerControllerProvider.overrideWith(() => player),
        playlistByIdProvider.overrideWith((ref, id) => Stream.value(playlists[id])),
        playlistsProvider.overrideWith((ref) => Stream.value(playlists.values.toList())),
      ],
      child: const PlaylistApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
    return ProviderScope.containerOf(tester.element(find.byType(PlaylistApp)));
  }

  MaterialApp materialApp(WidgetTester tester) => tester.widget<MaterialApp>(find.byType(MaterialApp));

  testWidgets('the app theme follows the accent color and theme mode chosen in Settings', (tester) async {
    final ProviderContainer container = await pumpApp(tester);
    const Color violet = Color(0xFF9B51E0);

    expect(materialApp(tester).theme!.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: kAccentColorChoices.first).primary);

    container.read(userAccentColorProvider.notifier).setAccentColor(violet);
    container.read(globalThemeModeProvider.notifier).setThemeMode(ThemeMode.dark);
    await tester.pump(const Duration(seconds: 1));

    final ColorScheme light = ColorScheme.fromSeed(seedColor: violet);
    final ColorScheme dark = ColorScheme.fromSeed(seedColor: violet, brightness: Brightness.dark);
    expect(materialApp(tester).theme!.colorScheme.primary, light.primary);
    expect(materialApp(tester).darkTheme!.colorScheme.primary, dark.primary);
    expect(materialApp(tester).themeMode, ThemeMode.dark);
  });

  testWidgets('the app theme ignores the Vibe of the playlist being played', (tester) async {
    await pumpApp(tester);
    final ColorScheme before = materialApp(tester).theme!.colorScheme;
    final ColorScheme beforeDark = materialApp(tester).darkTheme!.colorScheme;

    for (final String? id in ['red', 'preset', null]) {
      player.playlist(id);
      await tester.pump(const Duration(seconds: 1));
      expect(materialApp(tester).theme!.colorScheme, before, reason: 'playlist $id (clair)');
      expect(materialApp(tester).darkTheme!.colorScheme, beforeDark, reason: 'playlist $id (sombre)');
    }
  });
}
