import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/purge/local_notification_service.dart';
import 'package:playlist_app/core/purge/orphan_detector_service.dart';
import 'package:playlist_app/core/purge/orphan_track.dart';
import 'package:playlist_app/core/purge/purge_check_runner.dart';
import 'package:playlist_app/core/purge/purge_check_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Compte les lectures de la base (seul accès de la purge à celle-ci).
class _CountingDetector implements OrphanDetectorService {
  int scans = 0;

  @override
  Future<List<OrphanTrack>> findOrphans() async {
    scans++;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SilentNotifications implements LocalNotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _CountingDetector detector;
  late PurgeCheckStorage storage;
  late PurgeCheckRunner runner;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    detector = _CountingDetector();
    storage = PurgeCheckStorage();
    runner = PurgeCheckRunner(storage, detector, _SilentNotifications());
  });

  test('background task: never the first check — the app creates the database (recette 1.3.2+9)', () async {
    await runner.runIfDue(inBackground: true);

    expect(detector.scans, 0, reason: 'la base ne doit pas être ouverte par la tâche');
    expect(await storage.loadLastCheck(), isNull, reason: 'le premier contrôle reste à faire par l\'app');
  });

  test('app launch: the first check runs and is recorded', () async {
    await runner.runIfDue();

    expect(detector.scans, 1);
    expect(await storage.loadLastCheck(), isNotNull);
  });

  test('background task: runs normally once the app has checked and 30 days have passed', () async {
    await storage.saveLastCheck(DateTime.now().subtract(const Duration(days: 31)));

    await runner.runIfDue(inBackground: true);

    expect(detector.scans, 1);
  });
}
