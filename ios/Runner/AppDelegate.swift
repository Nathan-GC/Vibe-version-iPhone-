import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Identifiant de la tâche périodique de purge des orphelins (Étape 7) :
  /// identique à `orphanPurgeTaskName` côté Dart
  /// (lib/core/purge/purge_background_scheduler.dart) et déclaré dans
  /// `BGTaskSchedulerPermittedIdentifiers` (Info.plist).
  private static let orphanPurgeTaskIdentifier = "orphan_purge_daily_check"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Notifications locales (flutter_local_notifications) : affichées aussi
    // quand l'app est au premier plan (repli de la purge au lancement).
    // (forme recommandée par le README de flutter_local_notifications).
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate

    // Moteur Flutter secondaire créé par workmanager pour la tâche
    // d'arrière-plan : il a besoin des plugins (shared_preferences,
    // path_provider, flutter_local_notifications...) comme le moteur principal.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // BGTaskScheduler exige l'enregistrement du gestionnaire AVANT la fin du
    // lancement ; la planification elle-même est faite côté Dart
    // (PurgeBackgroundScheduler.initialize -> registerPeriodicTask).
    // Fréquence : quotidienne, comme sur Android — iOS reste libre d'espacer
    // l'exécution, d'où le repli au lancement (purgeCheckOnLaunchProvider).
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: AppDelegate.orphanPurgeTaskIdentifier,
      earliestBeginInSeconds: NSNumber(value: 24 * 60 * 60)
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
