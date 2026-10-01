import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';
import 'package:playlist_app/core/playlist_manifest/manifest_track_ref.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/playlists/data/import_track_matcher.dart';
import 'package:playlist_app/features/playlists/domain/import_match_plan.dart';

void main() {
  late AppDatabase db;
  late TrackRepository tracks;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tracks = TrackRepository(db);
  });

  tearDown(() => db.close());

  Future<void> addTrack(String title, String artist, {String album = ''}) {
    final String id = buildSanitizedKey(title: title, album: album, primaryArtist: artist);
    return tracks.upsertTrack(ScannedTrack(
      id: id,
      title: title,
      album: album,
      primaryArtist: artist,
      artists: [artist],
      filePath: '/music/$id.mp3',
      durationMs: 200000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
  }

  Future<ImportMatchPlan> plan(List<ManifestTrackRef> refs) async =>
      ImportTrackMatcher(await db.select(db.tracks).get()).plan(refs);

  test('exact key match is associated automatically', () async {
    await addTrack('One More Time', 'Daft Punk', album: 'Discovery');

    final ImportMatchPlan result =
        await plan(const [ManifestTrackRef(title: 'One More Time', artist: 'Daft Punk', album: 'Discovery')]);

    expect(result.entries.single.status, ImportMatchStatus.exact);
    expect(result.requiresManualReview, isFalse);
  });

  test('same title and artist ignoring accents, case, album and "(Remastered)" is a confident match', () async {
    await addTrack('Déjà Vu', 'Beyoncé', album: 'B\'Day');

    final ImportMatchPlan result =
        await plan(const [ManifestTrackRef(title: 'DEJA VU (Remastered 2011)', artist: 'Beyonce')]);

    expect(result.entries.single.status, ImportMatchStatus.confident);
    expect(result.entries.single.match?.title, 'Déjà Vu');
  });

  test('several versions of the same song by the same artist are ambiguous', () async {
    await addTrack('Halo', 'Beyoncé', album: 'I Am... Sasha Fierce');
    await addTrack('Halo', 'Beyoncé', album: 'Live at Wynn');

    final ImportMatchPlan result = await plan(const [ManifestTrackRef(title: 'Halo', artist: 'Beyoncé')]);

    expect(result.entries.single.status, ImportMatchStatus.ambiguous);
    expect(result.entries.single.candidates, hasLength(2));
    expect(result.requiresManualReview, isTrue);
  });

  test('the album breaks the tie between versions when it matches exactly one', () async {
    await addTrack('Halo', 'Beyoncé', album: 'I Am... Sasha Fierce');
    await addTrack('Halo', 'Beyoncé', album: 'Live at Wynn');

    final ImportMatchPlan result =
        await plan(const [ManifestTrackRef(title: 'Halo', artist: 'Beyonce', album: 'Live at Wynn')]);

    expect(result.entries.single.status, ImportMatchStatus.confident);
    expect(result.entries.single.match?.album, 'Live at Wynn');
  });

  test('the same title by another artist is never associated automatically', () async {
    await addTrack('Halo', 'Depeche Mode');

    final ImportMatchPlan result = await plan(const [ManifestTrackRef(title: 'Halo', artist: 'Beyoncé')]);

    expect(result.entries.single.status, ImportMatchStatus.titleOnly);
    expect(result.entries.single.match, isNull);
    expect(result.entries.single.candidates.single.artists, ['Depeche Mode']);
  });

  test('a title absent from the library is notFound, with same-artist suggestions sharing a word', () async {
    await addTrack('Around the World (Radio Edit)', 'Daft Punk');
    await addTrack('Digital Love', 'Daft Punk');

    final ImportMatchPlan result =
        await plan(const [ManifestTrackRef(title: 'Around the World - Live 1997', artist: 'Daft Punk')]);

    expect(result.entries.single.status, ImportMatchStatus.notFound);
    expect(result.entries.single.candidates.map((t) => t.title), ['Around the World (Radio Edit)']);
    expect(result.autoResolution, [null]);
  });

  test('a local track is never auto-associated to two titles of the same manifest', () async {
    await addTrack('Intro', 'The xx');

    final ImportMatchPlan result = await plan(const [
      ManifestTrackRef(title: 'Intro', artist: 'The xx'),
      ManifestTrackRef(title: 'Intro', artist: 'The xx'),
    ]);

    expect(result.entries[0].isAutoMatched, isTrue);
    expect(result.entries[1].isAutoMatched, isFalse);
  });
}
