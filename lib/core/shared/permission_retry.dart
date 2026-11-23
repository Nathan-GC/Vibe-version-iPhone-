import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Demande une permission avec retry/backoff : juste après le premier frame,
/// l'attachement natif de l'Activity Android à permission_handler peut ne pas
/// être terminé — course intermittente confirmée sur émulateur (passe
/// parfois, échoue parfois avec `PlatformException("Unable to detect current
/// Android Activity")` sur un run par ailleurs identique).
/// Accès en lecture aux fichiers audio du téléphone ; `true` si accordé.
/// Android 13+ : READ_MEDIA_AUDIO (`Permission.audio`). Android 12 et moins :
/// cette permission n'existe pas — permission_handler renvoie alors « refusé »
/// sans dialogue — et c'est READ_EXTERNAL_STORAGE (`Permission.storage`,
/// déclarée `maxSdkVersion="32"` dans le manifeste) qui donne l'accès. Sur
/// Android 13+, la demande de `storage` revient « refusé » sans dialogue : les
/// deux demandes successives n'affichent donc jamais qu'un seul dialogue.
Future<bool> requestAudioFilesAccess() async {
  Future<bool> granted() async =>
      (await Permission.audio.status).isGranted || (await Permission.storage.status).isGranted;
  if (await granted()) return true;
  await requestPermissionWithRetry(Permission.audio);
  if (await granted()) return true;
  await requestPermissionWithRetry(Permission.storage);
  return granted();
}

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
