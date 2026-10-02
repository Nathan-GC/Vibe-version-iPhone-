import 'local_notification_service.dart';
import 'orphan_detector_service.dart';
import 'orphan_track.dart';
import 'purge_check_storage.dart';

/// Logique pure "vérifier si 30 jours se sont écoulés, et si oui scanner +
/// notifier" — partagée entre la tâche WorkManager (isolate séparé) et le
/// repli exécuté au lancement de l'app (voir purge_providers.dart).
class PurgeCheckRunner {
  PurgeCheckRunner(this._storage, this._detector, this._notifications);

  final PurgeCheckStorage _storage;
  final OrphanDetectorService _detector;
  final LocalNotificationService _notifications;

  static const Duration checkInterval = Duration(days: 30);

  /// [inBackground] : tâche WorkManager, qui laisse toujours le premier
  /// contrôle à l'app (au lancement, voir purgeCheckOnLaunchProvider) — c'est
  /// l'app qui crée la base au premier lancement. Deux connexions la créant en
  /// même temps faisaient échouer celle de l'app ("database is locked" sur
  /// CREATE TABLE, import perdu — recette 1.3.2+9).
  Future<List<OrphanTrack>> runIfDue({bool inBackground = false}) async {
    final DateTime? lastCheck = await _storage.loadLastCheck();
    if (lastCheck == null && inBackground) return const [];
    final DateTime now = DateTime.now();
    if (lastCheck != null && now.difference(lastCheck) < checkInterval) {
      return const [];
    }

    final List<OrphanTrack> orphans = await _detector.findOrphans();
    await _storage.saveLastCheck(now);

    if (orphans.isNotEmpty) {
      await _notifications.showOrphanCleanupNotification(orphans.length);
    }
    return orphans;
  }
}
