import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/database/database_provider.dart';
import 'local_notification_service.dart';
import 'orphan_detector_service.dart';
import 'orphan_purge_service.dart';
import 'purge_check_runner.dart';
import 'purge_check_storage.dart';

final Provider<OrphanDetectorService> orphanDetectorServiceProvider = Provider<OrphanDetectorService>((ref) {
  return OrphanDetectorService(ref.watch(appDatabaseProvider));
});

final Provider<OrphanPurgeService> orphanPurgeServiceProvider = Provider<OrphanPurgeService>((ref) {
  return OrphanPurgeService(ref.watch(appDatabaseProvider));
});

final Provider<PurgeCheckStorage> purgeCheckStorageProvider = Provider<PurgeCheckStorage>((ref) => PurgeCheckStorage());

/// Instance partagée : côté app au premier plan, `initialize()` (avec le
/// callback de tap) est appelé une fois dans app/app.dart avant que ce
/// provider ne serve à autre chose.
final Provider<LocalNotificationService> localNotificationServiceProvider =
    Provider<LocalNotificationService>((ref) => LocalNotificationService());

/// Repli exécuté au lancement de l'app : si la tâche d'arrière-plan n'a pas pu
/// s'exécuter (throttling iOS, app jamais relancée pendant 30 jours...), le
/// contrôle a quand même lieu ici.
final FutureProvider<void> purgeCheckOnLaunchProvider = FutureProvider<void>((ref) async {
  final PurgeCheckRunner runner = PurgeCheckRunner(
    ref.watch(purgeCheckStorageProvider),
    ref.watch(orphanDetectorServiceProvider),
    ref.watch(localNotificationServiceProvider),
  );
  await runner.runIfDue();
});
