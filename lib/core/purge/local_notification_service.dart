import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../platform/app_platform.dart';
import '../shared/permission_retry.dart';

/// Notification locale "Storage Cleanup" (Étape 7.2). Le callback de tap
/// n'est câblé que côté app au premier plan (un isolate d'arrière-plan n'a
/// pas de UI vers laquelle naviguer) — voir app/app.dart.
class LocalNotificationService {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> initialize({void Function()? onNotificationTap}) async {
    // iOS : l'autorisation (alerte, badge, son) est demandée par
    // flutter_local_notifications lui-même à l'initialisation, via
    // `DarwinInitializationSettings` ci-dessous — permission_handler n'y
    // est pas utilisé (son groupe "notification" n'est pas compilé côté iOS).
    if (!AppPlatform.isIOS) {
      await requestPermissionWithRetry(Permission.notification);
    }

    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();

    await _plugin.initialize(
      settings: const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (response) => onNotificationTap?.call(),
    );
  }

  Future<void> showOrphanCleanupNotification(int orphanCount) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'storage_cleanup',
      'Storage Cleanup',
      channelDescription: 'Alerte de fichiers audio orphelins détectés localement',
      importance: Importance.defaultImportance,
    );
    const NotificationDetails details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());

    await _plugin.show(
      id: 0,
      title: 'Storage Cleanup',
      body: '$orphanCount unused tracks found',
      notificationDetails: details,
    );
  }
}
