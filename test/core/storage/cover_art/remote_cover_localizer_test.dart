import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/cover_art/remote_cover_auto_trigger.dart';
import 'package:playlist_app/core/storage/cover_art/remote_cover_localizer.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/core/storage/storage_manager/storage_manager_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDisk extends DiskSpacePlus {
  _FakeDisk([this.freeMb]);
  final double? freeMb;

  @override
  Future<double?> get getFreeDiskSpace async => freeMb;
}

/// Adaptateur Dio simulé : journalise les URL demandées, renvoie une image
/// factice (ou échoue) — aucun accès réseau réel.
class _CoverAdapter implements HttpClientAdapter {
  final List<Uri> requested = [];
  bool fail = false;
  String contentType = 'image/jpeg';
  FutureOr<void> Function()? onFetch;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    await onFetch?.call();
    if (fail) throw DioException(requestOptions: options, type: DioExceptionType.connectionError);
    return ResponseBody.fromBytes(
      Uint8List.fromList([1, 2, 3, 4]),
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late TrackRepository repository;
  late Directory root;
  late _CoverAdapter adapter;
  late RemoteCoverLocalizer localizer;

  RemoteCoverLocalizer build({Future<bool> Function()? gate, DiskSpacePlus? disk}) => RemoteCoverLocalizer(
        repository: repository,
        storage: StorageManagerService(diskSpace: disk ?? _FakeDisk(), appFolderResolver: () async => root),
        dio: Dio()..httpClientAdapter = adapter,
        automaticGate: gate ?? () async => true,
      );

  // Garde RGPD réelle (onboarding terminé + interrupteur), lue dans SharedPreferences.
  RemoteCoverLocalizer buildWithRealGate() => RemoteCoverLocalizer(
        repository: repository,
        storage: StorageManagerService(diskSpace: _FakeDisk(), appFolderResolver: () async => root),
        dio: Dio()..httpClientAdapter = adapter,
      );

  Future<void> addTrack(String id, {String cover = ''}) async {
    await repository.upsertTrack(ScannedTrack(
      id: id,
      title: 'Title $id',
      album: '',
      primaryArtist: 'Artist',
      artists: const ['Artist'],
      filePath: '/music/$id.mp3',
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
    if (cover.isNotEmpty) await repository.updateCoverArtPath(id, cover);
  }

  Future<String> coverOf(String id) async => (await repository.findById(id))!.coverArtPath;

  List<File> coverFiles() {
    final Directory dir = Directory(p.join(root.path, 'track_covers'));
    return dir.existsSync() ? dir.listSync().whereType<File>().toList() : [];
  }

  setUp(() async {
    // Nouveau scan de la bibliothèque déjà fait : seule la garde RGPD est en jeu.
    SharedPreferences.setMockInitialValues({'onboarding.full_scan_completed': true, 'library.rescan_done_version': 1});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
    root = await Directory.systemTemp.createTemp('remote_cover_test');
    adapter = _CoverAdapter();
    localizer = build();
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  group('localizeTrack', () {
    test('downloads the http cover once, stores it locally and rewrites the database', () async {
      await addTrack('t1', cover: 'https://coverartarchive.org/release/abc/front-500');

      expect(await localizer.localizeTrack('t1'), isTrue);

      final String cover = await coverOf('t1');
      expect(cover.startsWith('http'), isFalse);
      expect(p.dirname(cover), p.join(root.path, 'track_covers'));
      expect(File(cover).readAsBytesSync(), [1, 2, 3, 4]);
      expect(cover, endsWith('.jpg'));
      expect(coverFiles().map((f) => f.path), [cover]);
      expect(adapter.requested, hasLength(1));
    });

    test('asks Apple for 600x600 instead of the stored 1000x1000', () async {
      await addTrack('t1', cover: 'https://is1-ssl.mzstatic.com/image/thumb/Music/a/1000x1000bb.jpg');

      expect(await localizer.localizeTrack('t1'), isTrue);

      expect(adapter.requested.single.toString(), 'https://is1-ssl.mzstatic.com/image/thumb/Music/a/600x600bb.jpg');
    });

    test('a network failure returns false and leaves the database and the disk untouched', () async {
      const String url = 'https://is1-ssl.mzstatic.com/image/thumb/Music/a/1000x1000bb.jpg';
      await addTrack('t1', cover: url);
      adapter.fail = true;

      expect(await localizer.localizeTrack('t1'), isFalse);

      expect(await coverOf('t1'), url);
      expect(coverFiles(), isEmpty);
    });

    test('a non-image answer is rejected', () async {
      const String url = 'https://example.com/cover';
      await addTrack('t1', cover: url);
      adapter.contentType = 'text/html';

      expect(await localizer.localizeTrack('t1'), isFalse);

      expect(await coverOf('t1'), url);
      expect(coverFiles(), isEmpty);
    });

    test('not enough free space returns false without writing', () async {
      const String url = 'https://example.com/cover.jpg';
      await addTrack('t1', cover: url);

      expect(await build(disk: _FakeDisk(0)).localizeTrack('t1'), isFalse);

      expect(await coverOf('t1'), url);
      expect(coverFiles(), isEmpty);
    });

    test('a cover changed meanwhile is never overwritten and the downloaded file is removed', () async {
      await addTrack('t1', cover: 'https://example.com/old.jpg');
      adapter.onFetch = () => repository.updateCoverArtPath('t1', '/local/chosen.jpg');

      expect(await localizer.localizeTrack('t1'), isFalse);

      expect(await coverOf('t1'), '/local/chosen.jpg');
      expect(coverFiles(), isEmpty);
    });

    test('a local cover or no cover triggers no request', () async {
      await addTrack('t1', cover: '/local/cover.jpg');
      await addTrack('t2');

      expect(await localizer.localizeTrack('t1'), isFalse);
      expect(await localizer.localizeTrack('t2'), isFalse);

      expect(adapter.requested, isEmpty);
    });

    test('an explicit localization ignores the automatic gate (switch OFF)', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding.full_scan_completed': true,
        'privacy.auto_enrich_on_import': false,
      });
      await addTrack('t1', cover: 'https://example.com/1.jpg');

      expect(await buildWithRealGate().localizeTrack('t1'), isTrue);
    });
  });

  group('localizePending', () {
    test('localizes every http cover sequentially and counts them', () async {
      await addTrack('t1', cover: 'https://example.com/1.jpg');
      await addTrack('t2', cover: 'https://example.com/2.jpg');
      await addTrack('t3', cover: '/local/3.jpg');

      expect(await localizer.localizePending(), 2);

      expect(adapter.requested, hasLength(2));
      expect(await repository.trackIdsWithRemoteCover(), isEmpty);
    });

    test('overlapping calls share one pass', () async {
      await addTrack('t1', cover: 'https://example.com/1.jpg');
      await addTrack('t2', cover: 'https://example.com/2.jpg');

      final List<int> counts = await Future.wait([localizer.localizePending(), localizer.localizePending()]);

      expect(counts.first, 2);
      expect(adapter.requested, hasLength(2));
    });

    test('switch OFF: no request at all', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding.full_scan_completed': true,
        'library.rescan_done_version': 1,
        'privacy.auto_enrich_on_import': false,
      });
      await addTrack('t1', cover: 'https://example.com/1.jpg');

      expect(await buildWithRealGate().localizePending(), 0);

      expect(adapter.requested, isEmpty);
      expect(await coverOf('t1'), 'https://example.com/1.jpg');
    });

    test('first launch (onboarding not finished): no request at all', () async {
      SharedPreferences.setMockInitialValues({});
      await addTrack('t1', cover: 'https://example.com/1.jpg');

      expect(await buildWithRealGate().localizePending(), 0);

      expect(adapter.requested, isEmpty);
    });

    test('switch ON and onboarding finished: the pass goes through', () async {
      await addTrack('t1', cover: 'https://example.com/1.jpg');

      expect(await buildWithRealGate().localizePending(), 1);
    });

    test('library rescan still pending: automatic passes download nothing, an explicit one still does', () async {
      SharedPreferences.setMockInitialValues({'onboarding.full_scan_completed': true});
      await addTrack('t1', cover: 'https://example.com/1.jpg');

      expect(await buildWithRealGate().localizePending(), 0);
      expect(adapter.requested, isEmpty);
      expect(await coverOf('t1'), 'https://example.com/1.jpg');

      // Pas de garde sur l'action explicite (éditeur).
      expect(await buildWithRealGate().localizeTrack('t1'), isTrue);

      // Scan terminé : la passe automatique reprend son cours.
      SharedPreferences.setMockInitialValues(
          {'onboarding.full_scan_completed': true, 'library.rescan_done_version': 1});
      await addTrack('t2', cover: 'https://example.com/2.jpg');
      expect(await buildWithRealGate().localizePending(), 1);
    });

    test('the gate is re-read before each title (switch turned OFF mid-pass)', () async {
      await addTrack('t1', cover: 'https://example.com/1.jpg');
      await addTrack('t2', cover: 'https://example.com/2.jpg');
      int checks = 0;
      final RemoteCoverLocalizer gated = build(gate: () async => ++checks == 1);

      expect(await gated.localizePending(), 1);

      expect(adapter.requested, hasLength(1));
    });
  });

  group('RemoteCoverAutoTrigger', () {
    test('a new http cover appearing triggers a debounced pass; the initial value does not', () async {
      await addTrack('t1', cover: 'https://example.com/1.jpg');
      final RemoteCoverAutoTrigger trigger = RemoteCoverAutoTrigger(
        localizer: localizer,
        repository: repository,
        debounce: const Duration(milliseconds: 20),
      )..start();
      addTearDown(trigger.dispose);

      // Valeur initiale (1) : ignorée, c'est la passe de démarrage qui s'en charge.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(adapter.requested, isEmpty);

      await addTrack('t2', cover: 'https://example.com/2.jpg');
      // Attente par scrutation plutôt qu'un délai fixe : sous la charge de la
      // suite complète, flux Drift + anti-rebond + 2 téléchargements dépassaient
      // parfois 400 ms.
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((adapter.requested.length < 2 || (await repository.trackIdsWithRemoteCover()).isNotEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(adapter.requested, hasLength(2));
      expect(await repository.trackIdsWithRemoteCover(), isEmpty);
    });
  });
}
