import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/cover_art/remote_cover_auto_trigger.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/full_device_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/onboarding/data/onboarding_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCoverTrigger implements RemoteCoverAutoTrigger {
  @override
  Future<int> runPass() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeScan implements FullDeviceScanService {
  _FakeScan(this.tracks);

  final List<ScannedTrack> tracks;

  @override
  Future<List<ScannedTrack>> scan({
    required TrackRepository trackRepository,
    void Function(FullDeviceScanProgress progress)? onProgress,
  }) async =>
      tracks;
}

/// AN-28 à l'installation neuve : deux fichiers de même identité trouvés par le
/// scan plein-appareil doivent finir TOUS DEUX en base (le second en variante),
/// au lieu que le dernier écrase le premier.
void main() {
  late AppDatabase db;
  late Directory dir;

  setUp(() {
    // Enrichissement désactivé : aucun appel réseau, seul le renommage compte ici.
    SharedPreferences.setMockInitialValues({'privacy.auto_enrich_on_import': false});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('vibe_onboarding_variants');
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ScannedTrack scanned(String fileName, int durationMs) {
    final File file = File(p.join(dir.path, fileName))..writeAsBytesSync([1, 2, 3]);
    return ScannedTrack(
      id: 'nightcall__kavinsky',
      title: 'Nightcall',
      album: '',
      primaryArtist: 'Kavinsky',
      artists: const ['Kavinsky'],
      filePath: file.path,
      durationMs: durationMs,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    );
  }

  test('two files with the same identity are both in the library after the first scan', () async {
    final ScannedTrack drive = scanned('Kavinsky - Nightcall (Drive OST).mp3', 257000);
    final ScannedTrack feat = scanned('Kavinsky, Angèle, Phoenix - Nightcall.mp3', 179000);
    final ProviderContainer container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      fullDeviceScanServiceProvider.overrideWithValue(_FakeScan([drive, feat])),
      remoteCoverAutoTriggerProvider.overrideWithValue(_FakeCoverTrigger()),
    ]);
    addTearDown(container.dispose);

    await container.read(onboardingScanControllerProvider.notifier).start();

    final List<Track> rows = await (db.select(db.tracks)..orderBy([(t) => OrderingTerm(expression: t.id)])).get();
    expect(rows.map((t) => (t.id, t.filePath)), [
      ('nightcall__kavinsky', drive.filePath),
      ('nightcall__kavinsky~2', feat.filePath),
    ]);
  });
}
