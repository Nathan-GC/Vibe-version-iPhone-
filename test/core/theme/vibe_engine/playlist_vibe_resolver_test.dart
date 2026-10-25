import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/theme/vibe_engine/playlist_vibe_resolver.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Playlist> insertPlaylist(PlaylistsCompanion companion) async {
    await db.into(db.playlists).insert(companion);
    return (db.select(db.playlists)..where((p) => p.id.equals(companion.id.value))).getSingle();
  }

  test('a fixed preset always resolves to the fluid effect and no background video', () async {
    final Playlist playlist = await insertPlaylist(
      PlaylistsCompanion.insert(id: 'p1', title: 'Test', vibeStyle: const Value(VibePreset.neon)),
    );

    final VibeVisual vibe = playlist.resolvedVibe;

    expect(vibe.preset, VibePreset.neon);
    expect(vibe.effect, VibeCustomEffect.fluid);
    expect(vibe.customBackgroundVideoPath, isNull);
  });

  test('a custom preset resolves its stored effect (Section 4.2)', () async {
    final Playlist playlist = await insertPlaylist(
      PlaylistsCompanion.insert(
        id: 'p1',
        title: 'Test',
        vibeStyle: const Value(VibePreset.custom),
        customEffect: const Value(VibeCustomEffect.radiation),
      ),
    );

    expect(playlist.resolvedVibe.effect, VibeCustomEffect.radiation);
  });

  test('a custom preset surfaces a non-empty background video path (Section 4.3)', () async {
    final Playlist playlist = await insertPlaylist(
      PlaylistsCompanion.insert(
        id: 'p1',
        title: 'Test',
        vibeStyle: const Value(VibePreset.custom),
        customBackgroundVideoPath: const Value('/music/vibe_backgrounds/p1.mp4'),
      ),
    );

    expect(playlist.resolvedVibe.customBackgroundVideoPath, '/music/vibe_backgrounds/p1.mp4');
  });

  test('an unset background video path resolves to null rather than an empty string', () async {
    final Playlist playlist = await insertPlaylist(
      PlaylistsCompanion.insert(id: 'p1', title: 'Test', vibeStyle: const Value(VibePreset.custom)),
    );

    expect(playlist.resolvedVibe.customBackgroundVideoPath, isNull);
  });

  test('showCoverImage defaults to true for a freshly inserted playlist (Section 3)', () async {
    final Playlist playlist = await insertPlaylist(
      PlaylistsCompanion.insert(id: 'p1', title: 'Test', vibeStyle: const Value(VibePreset.retro)),
    );

    expect(playlist.resolvedVibe.showCoverImage, isTrue);
  });

  test('showCoverImage=false threads through for a fixed preset and for Custom (Section 3)', () async {
    final Playlist fixed = await insertPlaylist(
      PlaylistsCompanion.insert(
        id: 'p1',
        title: 'Test',
        vibeStyle: const Value(VibePreset.retro),
        showCoverImage: const Value(false),
      ),
    );
    expect(fixed.resolvedVibe.showCoverImage, isFalse);

    final Playlist custom = await insertPlaylist(
      PlaylistsCompanion.insert(
        id: 'p2',
        title: 'Test',
        vibeStyle: const Value(VibePreset.custom),
        showCoverImage: const Value(false),
      ),
    );
    expect(custom.resolvedVibe.showCoverImage, isFalse);
  });

  test('"Cacher la cover" applies to every preset, including those that previously had no toggle', () async {
    // Minimal/Glassmorphism/Organic/Space n'exposaient pas le bouton avant
    // la v1.2 : la valeur stockée y était ignorée. Chaque Vibe propose
    // désormais le réglage, qui doit donc être respecté partout.
    for (final VibePreset preset in VibePreset.values) {
      final Playlist playlist = await insertPlaylist(
        PlaylistsCompanion.insert(
          id: 'hidden-${preset.name}',
          title: 'Test',
          vibeStyle: Value(preset),
          showCoverImage: const Value(false),
        ),
      );
      expect(playlist.resolvedVibe.showCoverImage, isFalse, reason: '$preset should honour the hidden cover');
    }
  });

  Future<Playlist> insertCustom(String id, List<String> bg, {String accent = ''}) => insertPlaylist(
        PlaylistsCompanion.insert(
          id: id,
          title: 'Test',
          vibeStyle: const Value(VibePreset.custom),
          bgColors: Value(bg),
          customAccentColor: Value(accent),
        ),
      );

  test('the transparent sentinel resolves to a transparent gradient with a non-transparent accent', () async {
    final VibeVisual vibe = (await insertCustom('p1', ['00000000'])).resolvedVibe;

    expect(vibe.hasNoBackgroundColor, isTrue);
    expect(vibe.gradientColors.length, 2);
    expect(vibe.accentColor.a, 1);
    expect(vibe.accentColor, VibePreset.custom.accentColor);
  });

  test('the sentinel keeps an explicit accent', () async {
    final VibeVisual vibe = (await insertCustom('p1', ['00000000'], accent: 'FF123456')).resolvedVibe;

    expect(vibe.accentColor.toARGB32(), 0xFF123456);
  });

  test('an empty colour list still means the preset default (existing playlists unchanged)', () async {
    final VibeVisual vibe = (await insertCustom('p1', [])).resolvedVibe;

    expect(vibe.hasNoBackgroundColor, isFalse);
    expect(vibe.gradientColors, VibePreset.custom.gradientColors);
    expect(vibe.accentColor, VibePreset.custom.accentColor);
  });

  test('custom gradient colours keep the stored order', () async {
    final VibeVisual ab = (await insertCustom('p1', ['FFFF0000', 'FF0000FF'])).resolvedVibe;
    final VibeVisual ba = (await insertCustom('p2', ['FF0000FF', 'FFFF0000'])).resolvedVibe;

    expect(ab.gradientColors.map((c) => c.toARGB32()), [0xFFFF0000, 0xFF0000FF]);
    expect(ba.gradientColors.map((c) => c.toARGB32()), [0xFF0000FF, 0xFFFF0000]);
    expect(ab.hasNoBackgroundColor, isFalse);
    expect(ab.accentColor.toARGB32(), 0xFF0000FF);
    expect(ba.accentColor.toARGB32(), 0xFFFF0000);
  });

  test('a single chosen colour resolves to a flat background of that colour, like the Vibe Creator preview', () async {
    final VibeVisual vibe = (await insertCustom('p1', ['FF00FF00'])).resolvedVibe;

    expect(vibe.gradientColors.map((c) => c.toARGB32()), [0xFF00FF00, 0xFF00FF00]);
    expect(vibe.accentColor.toARGB32(), 0xFF00FF00);
  });
}
