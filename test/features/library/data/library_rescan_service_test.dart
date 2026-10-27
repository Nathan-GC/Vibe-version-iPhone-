import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_auto_enricher.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/library_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/library/data/library_rescan_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Identité « relue sur le fichier » scriptée par nom de fichier (sans extension).
class _FakeScan implements LibraryScanService {
  final Map<String, ScannedTrack?> identities = {};
  final List<String> identified = [];

  @override
  Future<ScannedTrack?> identify(File file) async {
    final String name = file.uri.pathSegments.last.replaceAll('.mp3', '');
    identified.add(name);
    return identities[name];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Un appel reçu par [_FakeEnricher.lookupMatch].
typedef _Lookup = ({String title, List<String> artists, int? durationMs, bool skipDurationCheck});

class _FakeEnricher implements TrackAutoEnricher {
  final List<_Lookup> lookups = [];
  MatchLookup Function(_Lookup lookup) respond = (_) => const MatchLookup.completed(null);
  Future<void> Function()? beforeAnswer;

  @override
  Future<MatchLookup> lookupMatch({
    required String title,
    required List<String> artists,
    int? localDurationMs,
    bool skipDurationCheck = false,
    bool retryOnFailure = true,
  }) async {
    final _Lookup lookup = (
      title: title,
      artists: artists,
      durationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
    );
    lookups.add(lookup);
    await beforeAnswer?.call();
    return respond(lookup);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const OnlineTrackResult _itunes = OnlineTrackResult(
  title: 'Halo',
  artist: 'Beyoncé',
  album: 'I Am... Sasha Fierce',
  releaseYear: 2008,
  coverArtUrl: 'https://is1.mzstatic.com/halo/1000x1000bb.jpg',
  genre: 'Pop',
  trackNumber: 3,
  discNumber: 1,
  trackCount: 12,
);

void main() {
  late AppDatabase db;
  late TrackRepository repository;
  late Directory dir;
  late _FakeScan scan;
  late _FakeEnricher enricher;
  late int finished;
  late List<RescanProgress?> progress;

  // Faux localiseur de pochettes : ids reçus, pochette en base à ce moment-là,
  // et comportement optionnel (ex. lever une erreur).
  late List<String> localized;
  late Map<String, String?> coversAtLocalization;
  Future<void> Function(String id)? onLocalize;

  LibraryRescanService build({Future<bool> Function()? gate, bool withLocalizer = true}) => LibraryRescanService(
        repository: repository,
        scanService: scan,
        enricher: enricher,
        onFinished: () async => finished++,
        onProgress: progress.add,
        gate: gate,
        localizeCover: withLocalizer
            ? (String id) async {
                localized.add(id);
                // Photographie de la base AU MOMENT de l'appel : la correspondance
                // du titre doit déjà être appliquée.
                coversAtLocalization[id] = (await repository.findById(id))?.coverArtPath;
                await onLocalize?.call(id);
                return true;
              }
            : null,
      );

  /// Titre déjà en base (ancien enrichissement) + identité relue par [identify].
  Future<void> addTrack(
    String id, {
    EnrichmentStatus status = EnrichmentStatus.enrichedAutoItunes,
    String cover = '',
    String album = 'Old Album',
    ScannedTrack? identity,
    bool withIdentity = true,
    String fileName = '',
    bool createFile = true,
  }) async {
    final String file = '${dir.path}/${fileName.isEmpty ? id : fileName}.mp3';
    if (createFile) File(file).writeAsStringSync('x');
    await repository.upsertTrack(ScannedTrack(
      id: id,
      title: 'Old $id',
      album: album,
      primaryArtist: 'Old Artist',
      artists: const ['Old Artist'],
      filePath: file,
      durationMs: 200000,
      genre: 'Rock',
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
    await (db.update(db.tracks)..where((t) => t.id.equals(id))).write(TracksCompanion(
      enrichmentStatus: Value(status),
      coverArtPath: Value(cover),
      releaseYear: const Value(1999),
      trackNumber: const Value(7),
    ));
    if (withIdentity) scan.identities[fileName.isEmpty ? id : fileName] = identity ?? _identity(id);
  }

  Future<Track> track(String id) async => (await repository.findById(id))!;

  Future<List<String>> artistIndex(String id) async => [
        for (final TrackArtist a in await (db.select(db.trackArtists)
              ..where((t) => t.trackId.equals(id))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get())
          a.artistName,
      ];

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'onboarding.full_scan_completed': true});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
    dir = await Directory.systemTemp.createTemp('rescan_test');
    scan = _FakeScan();
    enricher = _FakeEnricher();
    finished = 0;
    progress = [];
    localized = [];
    coversAtLocalization = {};
    onLocalize = null;
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  group('applying a match', () {
    test('rewrites identity, album, year, numbers, cover, tags and status like a fresh import + enrichment', () async {
      await addTrack('a', cover: 'https://old.example/cover.jpg');
      await repository.recordPlay('a');
      final Track before = await track('a');
      scan.identities['a'] = _identity('a', title: 'Halo', artists: ['Beyoncé', 'Feat Guest']);
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: false));

      await build().runIfPending();

      final Track after = await track('a');
      expect(after.title, 'Halo');
      expect(after.artists, ['Beyoncé', 'Feat Guest']);
      expect(await artistIndex('a'), ['Beyoncé', 'Feat Guest']);
      expect(after.album, 'I Am... Sasha Fierce');
      expect(after.releaseYear, 2008);
      expect(after.trackNumber, 3);
      expect(after.discNumber, 1);
      expect(after.trackCount, 12);
      // Ancienne pochette = URL http : remplacée.
      expect(after.coverArtPath, _itunes.coverArtUrl);
      // Repart de zéro : l'ancien genre « Rock » (tags du fichier absent) a disparu.
      expect(after.tags, ['Pop', 'Années 2000', 'Feel-good']);
      expect(after.enrichmentStatus, EnrichmentStatus.enrichedAutoItunes);
      expect(after.enrichmentAttempts, 0);
      expect(after.requiresUserReview, isFalse);
      // Jamais touchés.
      expect(after.id, before.id);
      expect(after.filePath, before.filePath);
      expect(after.durationSeconds, before.durationSeconds);
      expect(after.trimStartMs, before.trimStartMs);
      expect(after.playCount, 1);
      expect(after.createdAt, before.createdAt);
      final links = await (db.select(db.playlistTracks)..where((t) => t.trackId.equals('a'))).get();
      expect(links, hasLength(1));
    });

    test('the lookup uses the re-read identity, the stored duration and the video exemption', () async {
      await addTrack('a', fileName: 'Artist - Song (Official Video)');
      scan.identities['Artist - Song (Official Video)'] = _identity('a', title: 'Song', artists: ['Artist']);
      await addTrack('b');

      await build().runIfPending();

      expect(enricher.lookups, hasLength(2));
      expect(enricher.lookups[0].title, 'Song');
      expect(enricher.lookups[0].artists, ['Artist']);
      expect(enricher.lookups[0].durationMs, 200000);
      expect(enricher.lookups[0].skipDurationCheck, isTrue);
      expect(enricher.lookups[1].skipDurationCheck, isFalse);
    });

    test('a swapped match writes the clean iTunes title and artist', () async {
      await addTrack('a');
      scan.identities['a'] = _identity('a', title: 'Beyoncé', artists: ['Halo']);
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: true));

      await build().runIfPending();

      final Track after = await track('a');
      expect(after.title, 'Halo');
      expect(after.artists, ['Beyoncé']);
      expect(await artistIndex('a'), ['Beyoncé']);
    });

    test('no match: the previous enrichment is kept untouched, the pass still completes', () async {
      await addTrack('a', cover: '/local/cover.jpg');
      final Track before = await track('a');

      await build().runIfPending();

      final Track after = await track('a');
      expect(after.title, before.title);
      expect(after.artists, before.artists);
      expect(after.album, before.album);
      expect(after.tags, before.tags);
      expect(after.coverArtPath, before.coverArtPath);
      expect(after.enrichmentStatus, before.enrichmentStatus);
      expect((await prefs()).getInt(LibraryRescanService.doneVersionKey), 1);
    });

    test('a local cover is kept, an http one is replaced, an empty one is filled', () async {
      await addTrack('a', cover: '/local/own.jpg');
      await addTrack('b', cover: 'http://old.example/b.jpg');
      await addTrack('c');
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: false));

      await build().runIfPending();

      expect((await track('a')).coverArtPath, '/local/own.jpg');
      expect((await track('b')).coverArtPath, _itunes.coverArtUrl);
      expect((await track('c')).coverArtPath, _itunes.coverArtUrl);
    });

    test('album: the file tag wins over iTunes, iTunes over the old one, the old one is the last resort', () async {
      await addTrack('a', identity: _identity('a', album: 'Tag Album'));
      await addTrack('b');
      await addTrack('c');
      enricher.respond = (lookup) => MatchLookup.completed(EnrichmentMatch(
            lookup.title == 'T-c' ? const OnlineTrackResult(title: 'x', artist: 'y') : _itunes,
            swapped: false,
          ));

      await build().runIfPending();

      expect((await track('a')).album, 'Tag Album');
      expect((await track('b')).album, 'I Am... Sasha Fierce');
      expect((await track('c')).album, 'Old Album');
      // iTunes sans année ni numéros : les anciens sont conservés.
      expect((await track('c')).releaseYear, 1999);
      expect((await track('c')).trackNumber, 7);
    });

    test('the file genre is kept next to the iTunes keywords', () async {
      await addTrack('a', identity: _identity('a', genre: 'Rap FR'));
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: false));

      await build().runIfPending();

      expect((await track('a')).tags, ['Rap FR', 'Pop', 'Années 2000', 'Feel-good']);
    });
  });

  group('titles left as they are', () {
    test('user-chosen statuses are never looked up nor rewritten', () async {
      await addTrack('a', status: EnrichmentStatus.enrichedManualEdit);
      await addTrack('b', status: EnrichmentStatus.enrichedManualItunes);
      await addTrack('c', status: EnrichmentStatus.enrichedManualMusicBrainz);
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: false));

      await build().runIfPending();

      expect(enricher.lookups, isEmpty);
      expect((await track('a')).title, 'Old a');
      expect((await track('b')).title, 'Old b');
      expect((await track('c')).title, 'Old c');
      expect((await prefs()).getInt(LibraryRescanService.doneVersionKey), 1);
    });

    test('missing file, unreadable identity and ambiguous name are skipped without a request', () async {
      await addTrack('a', createFile: false);
      await addTrack('b', identity: null, withIdentity: false);
      await addTrack('c', identity: _identity('c', review: true));
      await addTrack('d');
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: false));

      await build().runIfPending();

      expect(enricher.lookups.map((l) => l.title), ['T-d']);
      expect((await track('a')).title, 'Old a');
      expect((await track('c')).title, 'Old c');
      expect((await track('d')).title, 'T-d');
      expect((await track('d')).album, 'I Am... Sasha Fierce');
      expect((await prefs()).getInt(LibraryRescanService.doneVersionKey), 1);
    });
  });

  group('network failure, cursor and resumption', () {
    test('a network failure stops the pass without moving the cursor nor setting the flag', () async {
      await addTrack('a');
      await addTrack('b');
      await addTrack('c');
      enricher.respond = (lookup) => lookup.title == 'T-b'
          ? const MatchLookup.networkFailed(serverResponded: true)
          : const MatchLookup.completed(null);

      await build().runIfPending();

      expect(enricher.lookups.map((l) => l.title), ['T-a', 'T-b']);
      expect((await prefs()).getString(LibraryRescanService.cursorKey), 'a');
      expect((await prefs()).getInt(LibraryRescanService.doneVersionKey), isNull);
      expect(await LibraryRescanService.isPending(), isTrue);
      expect(finished, 0);
      expect(progress.last, isNull, reason: 'banner removed when the pass stops');
    });

    test('the next launch resumes after the cursor (including the failed title) and completes', () async {
      await addTrack('a');
      await addTrack('b');
      await addTrack('c');
      enricher.respond = (lookup) => lookup.title == 'T-b'
          ? const MatchLookup.networkFailed(serverResponded: true)
          : const MatchLookup.completed(null);
      await build().runIfPending();
      enricher.lookups.clear();
      enricher.respond = (_) => const MatchLookup.completed(null);

      await build().runIfPending();

      expect(enricher.lookups.map((l) => l.title), ['T-b', 'T-c']);
      expect((await prefs()).getInt(LibraryRescanService.doneVersionKey), 1);
      expect((await prefs()).getString(LibraryRescanService.cursorKey), isNull);
    });

    test('an existing cursor is honoured: titles up to it are not visited again', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding.full_scan_completed': true,
        LibraryRescanService.cursorKey: 'b',
      });
      for (final String id in ['d', 'a', 'c', 'b']) {
        await addTrack(id);
      }

      await build().runIfPending();

      expect(enricher.lookups.map((l) => l.title), ['T-c', 'T-d']);
    });

    test('progress counts every title, resumed ones included, and ends with null', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding.full_scan_completed': true,
        LibraryRescanService.cursorKey: 'a',
      });
      for (final String id in ['a', 'b', 'c']) {
        await addTrack(id);
      }

      await build().runIfPending();

      expect(progress, [(done: 1, total: 3), (done: 2, total: 3), (done: 3, total: 3), null]);
    });
  });

  group('AN-19 : filet de sécurité contre un titre qui échoue toujours', () {
    Future<void> failOn(String title) async => enricher.respond = (lookup) => lookup.title == title
        ? const MatchLookup.networkFailed(serverResponded: true)
        : const MatchLookup.completed(null);

    test('a title failing on 3 consecutive passes is skipped and the scan completes', () async {
      await addTrack('a');
      await addTrack('b');
      await addTrack('c');
      await failOn('T-b');

      await build().runIfPending(); // passe 1 : a traité, b échoue.
      expect((await prefs()).getString(LibraryRescanService.cursorKey), 'a');
      expect((await prefs()).getString(LibraryRescanService.failIdKey), 'b');
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 1);
      await build().runIfPending(); // passe 2.
      expect((await prefs()).getString(LibraryRescanService.cursorKey), 'a');
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 2);
      expect(await LibraryRescanService.isPending(), isTrue);
      enricher.lookups.clear();

      await build().runIfPending(); // passe 3 : b est sauté, c traité, fin.

      expect(enricher.lookups.map((l) => l.title), ['T-b', 'T-c']);
      expect(await LibraryRescanService.isPending(), isFalse);
      expect((await prefs()).getInt(LibraryRescanService.doneVersionKey), 1);
      expect((await prefs()).getString(LibraryRescanService.cursorKey), isNull);
      expect((await prefs()).getString(LibraryRescanService.failIdKey), isNull);
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), isNull);
      expect(finished, 1);
      expect((await track('b')).title, 'Old b', reason: 'skipped title keeps its previous enrichment');
    });

    test('two failures are not enough: the title is still retried and the pass still stops', () async {
      await addTrack('a');
      await failOn('T-a');

      await build().runIfPending();
      await build().runIfPending();

      expect(await LibraryRescanService.isPending(), isTrue);
      expect(finished, 0);
      expect((await prefs()).getString(LibraryRescanService.cursorKey), isNull);
    });

    test('the counter restarts from zero once a title has been processed', () async {
      await addTrack('a');
      await addTrack('b');
      await failOn('T-a');
      await build().runIfPending();
      await build().runIfPending();
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 2);

      // Le réseau revient : a est traité, puis b échoue à son tour (autre titre).
      enricher.respond = (lookup) => lookup.title == 'T-b'
          ? const MatchLookup.networkFailed(serverResponded: true)
          : const MatchLookup.completed(null);
      await build().runIfPending();

      expect((await prefs()).getString(LibraryRescanService.cursorKey), 'a');
      expect((await prefs()).getString(LibraryRescanService.failIdKey), 'b');
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 1, reason: 'b starts at 1, not 3');
      expect(await LibraryRescanService.isPending(), isTrue);
    });

    test('completing the scan after earlier failures leaves no counter behind', () async {
      await addTrack('a');
      await failOn('T-a');
      await build().runIfPending();
      await build().runIfPending();

      enricher.respond = (_) => const MatchLookup.completed(null);
      await build().runIfPending(); // a est traité : fin du scan.
      expect(await LibraryRescanService.isPending(), isFalse);
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), isNull);
    });

    test('a different title failing resets the count instead of adding up', () async {
      await addTrack('a');
      await addTrack('b');
      await failOn('T-b');
      await build().runIfPending();
      await build().runIfPending();
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 2);

      // Le titre b disparaît de la bibliothèque : c'est c, un autre titre, qui échoue.
      await (db.delete(db.tracks)..where((t) => t.id.equals('b'))).go();
      await addTrack('c');
      await failOn('T-c');
      await build().runIfPending();

      expect((await prefs()).getString(LibraryRescanService.failIdKey), 'c');
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 1);
      expect(await LibraryRescanService.isPending(), isTrue);
    });

    // AN-30 : seul un échec où le serveur a répondu (5xx, 403, 429) compte ; être
    // hors ligne n'est pas la faute du titre.
    Future<void> offlineOn(String title) async => enricher.respond = (lookup) => lookup.title == title
        ? const MatchLookup.networkFailed(serverResponded: false)
        : const MatchLookup.completed(null);

    test('AN-30: offline passes (no server response) never skip the title nor touch the counter', () async {
      await addTrack('a');
      await addTrack('b');
      await offlineOn('T-b');

      for (int pass = 1; pass <= 5; pass++) {
        await build().runIfPending();
        expect((await prefs()).getString(LibraryRescanService.cursorKey), 'a', reason: 'pass $pass');
        expect((await prefs()).getInt(LibraryRescanService.failCountKey), isNull, reason: 'pass $pass');
        expect((await prefs()).getString(LibraryRescanService.failIdKey), isNull, reason: 'pass $pass');
        expect(await LibraryRescanService.isPending(), isTrue, reason: 'pass $pass');
      }
      expect(enricher.lookups.where((l) => l.title == 'T-b'), hasLength(5), reason: 'b retried each launch');
      expect((await track('b')).title, 'Old b');

      // Le réseau revient : b est enfin traité, jamais sauté.
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: false));
      await build().runIfPending();
      expect((await track('b')).album, 'I Am... Sasha Fierce');
      expect(await LibraryRescanService.isPending(), isFalse);
    });

    test('AN-30: 3 passes with a server response (503/429) still skip the title', () async {
      await addTrack('a');
      await failOn('T-a');

      await build().runIfPending();
      await build().runIfPending();
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 2);
      await build().runIfPending();

      expect(await LibraryRescanService.isPending(), isFalse);
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), isNull);
    });

    test('AN-30: an offline pass between two server failures neither resets nor increments the counter', () async {
      await addTrack('a');
      await failOn('T-a');
      await build().runIfPending(); // serveur : 1
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 1);

      await offlineOn('T-a');
      await build().runIfPending(); // coupure : toujours 1
      await build().runIfPending();
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 1);
      expect((await prefs()).getString(LibraryRescanService.failIdKey), 'a');
      expect(await LibraryRescanService.isPending(), isTrue);

      await failOn('T-a');
      await build().runIfPending(); // serveur : 2
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), 2);
      expect(await LibraryRescanService.isPending(), isTrue);
      await build().runIfPending(); // serveur : 3 -> sauté

      expect(await LibraryRescanService.isPending(), isFalse);
    });

    test('markDone clears a leftover counter', () async {
      SharedPreferences.setMockInitialValues({
        LibraryRescanService.failIdKey: 'b',
        LibraryRescanService.failCountKey: 2,
      });

      await LibraryRescanService.markDone();

      expect((await prefs()).getString(LibraryRescanService.failIdKey), isNull);
      expect((await prefs()).getInt(LibraryRescanService.failCountKey), isNull);
    });
  });

  group('AN-20 : pochettes http rapatriées pendant le scan', () {
    test('an http cover is localized right after its title is processed (match applied)', () async {
      await addTrack('a', cover: 'http://old.example/a.jpg');
      await addTrack('b', cover: '/local/b.jpg');
      enricher.respond = (_) => const MatchLookup.completed(EnrichmentMatch(_itunes, swapped: false));
      // Une exception levée ici serait avalée par le service : on note l'état.
      final List<int> lookupsSeen = [];
      onLocalize = (id) async => lookupsSeen.add(enricher.lookups.length);

      await build().runIfPending();

      expect(localized, ['a']);
      expect(lookupsSeen, [1], reason: 'localized before the next title is looked up');
      // La pochette vue par le localiseur est celle posée par la correspondance.
      expect(coversAtLocalization['a'], _itunes.coverArtUrl);
    });

    test('also when there is no match: the inherited http cover is localized', () async {
      await addTrack('a', cover: 'https://old.example/a.jpg');

      await build().runIfPending();

      expect(localized, ['a']);
      expect(coversAtLocalization['a'], 'https://old.example/a.jpg');
    });

    test('also for skipped titles (manual edit, missing file)', () async {
      await addTrack('a', status: EnrichmentStatus.enrichedManualEdit, cover: 'http://old.example/a.jpg');
      await addTrack('b', createFile: false, cover: 'http://old.example/b.jpg');

      await build().runIfPending();

      expect(enricher.lookups, isEmpty);
      expect(localized, ['a', 'b']);
    });

    test('a local or empty cover triggers no call', () async {
      await addTrack('a', cover: '/local/own.jpg');
      await addTrack('b');

      await build().runIfPending();

      expect(enricher.lookups, hasLength(2));
      expect(localized, isEmpty);
    });

    test('a title stopped by a network failure is not localized, the skipped one (safety net) is', () async {
      await addTrack('a', cover: 'http://old.example/a.jpg');
      enricher.respond = (_) => const MatchLookup.networkFailed(serverResponded: true);

      await build().runIfPending();
      expect(localized, isEmpty);
      await build().runIfPending();
      expect(localized, isEmpty);
      await build().runIfPending(); // 3e échec : sauté.

      expect(localized, ['a']);
    });

    test('a localizer failure (exception) never stops the pass', () async {
      await addTrack('a', cover: 'http://old.example/a.jpg');
      await addTrack('b', cover: 'http://old.example/b.jpg');
      onLocalize = (id) async => throw StateError('disque plein');

      await build().runIfPending();

      expect(localized, ['a', 'b']);
      expect(enricher.lookups.map((l) => l.title), ['T-a', 'T-b']);
      expect(await LibraryRescanService.isPending(), isFalse);
      expect(finished, 1);
    });

    test('without a localizer the pass works as before', () async {
      await addTrack('a', cover: 'http://old.example/a.jpg');

      await build(withLocalizer: false).runIfPending();

      expect(localized, isEmpty);
      expect(await LibraryRescanService.isPending(), isFalse);
    });

    test('the GDPR guard of the title comes first: a refused guard localizes nothing', () async {
      await addTrack('a', cover: 'http://old.example/a.jpg');

      await build(gate: () async => false).runIfPending();

      expect(localized, isEmpty);
    });
  });

  group('GDPR guard', () {
    test('first launch (onboarding not finished): no lookup, no progress, still pending', () async {
      SharedPreferences.setMockInitialValues({});
      await addTrack('a');

      await build().runIfPending();

      expect(enricher.lookups, isEmpty);
      expect(scan.identified, isEmpty);
      expect(progress.whereType<RescanProgress>(), isEmpty);
      expect(await LibraryRescanService.isPending(), isTrue);
    });

    test('switch OFF: no lookup, still pending', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding.full_scan_completed': true,
        'privacy.auto_enrich_on_import': false,
      });
      await addTrack('a');

      await build().runIfPending();

      expect(enricher.lookups, isEmpty);
      expect(await LibraryRescanService.isPending(), isTrue);
    });

    test('the guard is re-read before each title (switch turned OFF mid-pass)', () async {
      await addTrack('a');
      await addTrack('b');
      await addTrack('c');
      int checks = 0;

      await build(gate: () async => ++checks <= 2).runIfPending();

      // 1er contrôle : démarrage ; 2e : titre a ; 3e (refus) : titre b.
      expect(enricher.lookups.map((l) => l.title), ['T-a']);
      expect((await prefs()).getString(LibraryRescanService.cursorKey), 'a');
      expect(await LibraryRescanService.isPending(), isTrue);
      expect(finished, 0);
    });

    test('the real guard reads the switch from the preferences between titles', () async {
      await addTrack('a');
      await addTrack('b');
      enricher.respond = (lookup) {
        // L'utilisateur coupe l'interrupteur pendant la recherche du premier titre.
        SharedPreferences.setMockInitialValues(
            {'onboarding.full_scan_completed': true, 'privacy.auto_enrich_on_import': false});
        return const MatchLookup.completed(null);
      };

      await build().runIfPending();

      expect(enricher.lookups, hasLength(1));
    });
  });

  group('one-shot flag', () {
    test('flag set, cursor cleared, cover pass triggered; a second run does nothing', () async {
      await addTrack('a');
      await addTrack('b');

      await build().runIfPending();

      expect((await prefs()).getInt(LibraryRescanService.doneVersionKey), LibraryRescanService.currentRescanVersion);
      expect((await prefs()).getString(LibraryRescanService.cursorKey), isNull);
      expect(await LibraryRescanService.isPending(), isFalse);
      expect(finished, 1);
      final int lookups = enricher.lookups.length;

      await build().runIfPending();

      expect(enricher.lookups, hasLength(lookups));
      expect(finished, 1);
    });

    test('markDone (fresh install) makes the rescan a no-op', () async {
      await addTrack('a');
      expect(await LibraryRescanService.isPending(), isTrue);

      await LibraryRescanService.markDone();
      await build().runIfPending();

      expect(await LibraryRescanService.isPending(), isFalse);
      expect(enricher.lookups, isEmpty);
    });

    test('an older version flag is still pending', () async {
      SharedPreferences.setMockInitialValues({LibraryRescanService.doneVersionKey: 0});
      expect(await LibraryRescanService.isPending(), isTrue);
    });

    test('only one pass at a time', () async {
      await addTrack('a');
      final Completer<void> release = Completer<void>();
      enricher.beforeAnswer = () => release.future;
      final LibraryRescanService service = build();

      final Future<void> first = service.runIfPending();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.runIfPending();
      release.complete();
      await first;

      expect(enricher.lookups, hasLength(1));
    });
  });
}

ScannedTrack _identity(
  String id, {
  String? title,
  List<String> artists = const ['Artist'],
  String album = '',
  String? genre,
  bool review = false,
}) {
  return ScannedTrack(
    id: 'new-$id',
    title: title ?? 'T-$id',
    album: album,
    primaryArtist: artists.first,
    artists: artists,
    filePath: '/ignored/$id.mp3',
    durationMs: 200000,
    genre: genre,
    requiresUserReview: review,
    trimStartMs: 0,
    trimEndMs: 0,
  );
}
