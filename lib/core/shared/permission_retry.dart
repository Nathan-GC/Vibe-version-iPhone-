import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Demande une permission avec retry/backoff : juste après le premier frame,
/// l'attachement natif de l'Activity Android à permission_handler peut ne pas
/// être terminé — course intermittente confirmée sur émulateur (passe
/// parfois, échoue parfois avec `PlatformException("Unable to detect current
/// Android Activity")` sur un run par ailleurs identique).
Future<void> requestPermissionWithRetry(Permission permission, {int attempts = 5}) async {
  for (int attempt = 1; attempt <= attempts; attempt++) {
    try {
      await permission.request();
      return;
    } on PlatformException {
      if (attempt == attempts) return;
      await Future.delayed(Duration(milliseconds: 200 * attempt));
    }
  }
}
