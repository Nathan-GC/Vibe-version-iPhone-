import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/preview_player_controller.dart';
import 'package:playlist_app/core/networking/metadata_api_client/metadata_api_client.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/storage/cover_art/remote_cover_localizer.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';
import 'package:playlist_app/features/library/presentation/metadata_editor_modal.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Client iTunes factice : compte les recherches, aucun réseau.
class _FakeApi extends MetadataApiClient {
  int searches = 0;
  List<OnlineTrackResult> results = const [];

  @override
  Future<List<OnlineTrackResult>> searchByArtistAndTitle({
    String? artist,
    String? title,
    int limit = 15,
    CancelToken? cancelToken,
  }) async {
    searches++;
    return results;
  }
}

class _FakeLocalizer implements RemoteCoverLocalizer {
  final List<String> localized = [];

  @override
  Future<bool> localizeTrack(String trackId) async {
    localized.add(trackId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  late TrackRepository repository;
  late _FakeApi api;
  late _FakeLocalizer localizer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
    api = _FakeApi();
    localizer = _FakeLocalizer();
  });
  tearDown(() => db.close());

  Future<Track> insertTrack(WidgetTester tester, {String cover = ''}) async {
    return (await tester.runAsync(() async {
      await repository.upsertTrack(const ScannedTrack(
        id: 't1',
        title: 'Some Title',
        album: '',
        primaryArtist: 'Some Artist',
        artists: ['Some Artist'],
        filePath: '/music/t1.mp3',
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      if (cover.isNotEmpty) await repository.updateCoverArtPath('t1', cover);
      return repository.findById('t1');
    }))!;
  }

  Future<void> open(WidgetTester tester, Track track, {String? initialSearchQuery}) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        metadataApiClientProvider.overrideWithValue(api),
        remoteCoverLocalizerProvider.overrideWithValue(localizer),
        previewPlayerControllerProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        home: Scaffold(body: MetadataEditorModal(track: track, initialSearchQuery: initialSearchQuery)),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('switch OFF: opening the editor sends nothing, the explicit button launches the search', (tester) async {
    SharedPreferences.setMockInitialValues({'privacy.auto_enrich_on_import': false});
    await open(tester, await insertTrack(tester));

    expect(api.searches, 0);
    final Finder button = find.text('Rechercher sur iTunes');
    expect(button, findsOneWidget);

    await tester.tap(find.text('Rechercher sur iTunes'));
    await tester.pump();
    await tester.pump();

    expect(api.searches, 1);
    expect(find.text('Rechercher sur iTunes'), findsNothing);
  });

  testWidgets('switch ON: the search starts on opening, no button', (tester) async {
    await open(tester, await insertTrack(tester));

    expect(api.searches, 1);
    expect(find.text('Rechercher sur iTunes'), findsNothing);
  });

  testWidgets('switch OFF but explicit sparkle search (initialSearchQuery): searches on opening', (tester) async {
    SharedPreferences.setMockInitialValues({'privacy.auto_enrich_on_import': false});
    await open(tester, await insertTrack(tester), initialSearchQuery: 'some file name');

    expect(api.searches, 1);
  });

  testWidgets('a cover URL coming from the database is not loaded: placeholder, and not localized on save', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'privacy.auto_enrich_on_import': false});
    await open(tester, await insertTrack(tester, cover: 'https://example.com/cover.jpg'));

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.add_photo_alternate_outlined), findsOneWidget);

    await tester.tap(find.text('Enregistrer'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();

    expect(localizer.localized, isEmpty);
  });

  testWidgets('a cover chosen from the suggestions is localized on save, even with the switch OFF', (tester) async {
    SharedPreferences.setMockInitialValues({'privacy.auto_enrich_on_import': false});
    api.results = const [
      OnlineTrackResult(title: 'Some Title', artist: 'Some Artist', coverArtUrl: 'https://example.com/new.jpg'),
    ];
    await open(tester, await insertTrack(tester));
    await tester.tap(find.text('Rechercher sur iTunes'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Some Artist - Some Title'));
    await tester.pump();
    await tester.tap(find.text('Enregistrer'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();

    expect(localizer.localized, ['t1']);
    expect((await tester.runAsync(() => repository.findById('t1')))!.coverArtPath, 'https://example.com/new.jpg');
  });
}
