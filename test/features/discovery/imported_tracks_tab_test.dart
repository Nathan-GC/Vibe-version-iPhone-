import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/blacklist_repository.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/library_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/discovery/presentation/imported_tracks_tab.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';

class _RecordingPlayerController extends PlayerController {
  final List<Set<String>> removed = [];

  @override
  PlayerSnapshot build() => const PlayerSnapshot(status: PlaybackStatus.idle);

  @override
  Future<void> removeTracks(Set<String> trackIds) async => removed.add(trackIds);
}

ScannedTrack _scanned(String id, String filePath) => ScannedTrack(
      id: id,
      title: 'Song $id',
      album: '',
      primaryArtist: 'Artist',
      artists: const ['Artist'],
      filePath: filePath,
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    );

/// Identité lue sans ffprobe : clé = nom du fichier choisi.
class _FakeScanService extends LibraryScanService {
  @override
  Future<ScannedTrack?> identify(File file) async => _scanned(file.uri.pathSegments.last.split('.').first, file.path);
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    for (final String id in ['a', 'b']) {
      await TrackRepository(db).upsertTrack(_scanned(id, '/music/$id.mp3'));
    }
  });

  tearDown(() => db.close());

  /// Les écritures Drift se terminent hors de l'horloge simulée du test.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  testWidgets('selected tracks are masked, then restored from the blacklist', (tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        playerControllerProvider.overrideWith(() => player),
        blacklistRepositoryProvider.overrideWithValue(BlacklistRepository(db, fileExists: (_) async => true)),
      ],
      child: const MaterialApp(home: Scaffold(body: ImportedTracksTab())),
    ));
    await settle(tester);

    // Masquage manuel : sélection puis confirmation.
    await tester.tap(find.text('Song a'));
    await tester.pump();
    expect(find.text('1 titre sélectionné'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Masquer')));
    await settle(tester);

    expect(find.text('Song a'), findsNothing);
    expect(find.text('Song b'), findsOneWidget);
    expect(
        player.removed,
        [
          {'a'}
        ],
        reason: 'retiré aussi de la file de lecture');

    // Liste noire : titre, artiste et chemin, puis restauration.
    await tester.tap(find.text('Liste noire (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Song a'), findsOneWidget);
    expect(find.textContaining('/music/a.mp3'), findsOneWidget);
    await tester.tap(find.text('Restaurer'));
    await settle(tester);

    expect(find.textContaining('Liste noire vide'), findsOneWidget);
    expect(await tester.runAsync(() => TrackRepository(db).findById('a')), isNotNull);

    // Démontage : laisse Drift fermer ses flux (Timer.run) avant db.close().
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('"Masquer un fichier..." blacklists device files, imported or not', (tester) async {
    final _RecordingPlayerController player = _RecordingPlayerController();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        playerControllerProvider.overrideWith(() => player),
        libraryScanServiceProvider.overrideWithValue(_FakeScanService()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ImportedTracksTab(pickAudioFiles: () async => ['/picker-cache/c.mp3', '/picker-cache/a.mp3']),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('Liste noire (0)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Masquer un fichier...'));
    await settle(tester);

    expect(find.text('2 fichiers ajoutés à la liste noire.'), findsOneWidget);
    expect(find.text('Liste noire (2)'), findsOneWidget);
    expect(find.text('Song c'), findsOneWidget);
    expect(find.text('Song a'), findsOneWidget);
    expect(
        player.removed,
        [
          {'a'}
        ],
        reason: 'déjà en bibliothèque : retiré aussi de la file de lecture');
    final TrackRepository tracks = TrackRepository(db);
    expect(await tester.runAsync(() => tracks.findById('a')), isNull);
    // c, jamais importé : refusé par un scan ultérieur, où qu'il soit trouvé.
    await tester.runAsync(() => tracks.upsertTrack(_scanned('c', '/music/c.mp3')));
    expect(await tester.runAsync(() => tracks.findById('c')), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
