import '../core/purge/purge_background_scheduler.dart';

/// Initialise ce qui doit être prêt avant le premier frame : la tâche
/// d'arrière-plan de purge mensuelle des orphelins (Étape 7). Les demandes de
/// permission (audio, notifications) attendent que l'Activity Android soit
/// attachée — voir PlaylistApp.initState — sans quoi permission_handler lève
/// `PlatformException(... Unable to detect current Android Activity ...)`.
Future<void> bootstrap() async {
  await PurgeBackgroundScheduler().initialize();
}
