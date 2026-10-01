import 'package:shared_preferences/shared_preferences.dart';

/// Persiste `last_purge_check_timestamp` (Étape 7.1) — consulté aussi bien
/// par la tâche d'arrière-plan que par le repli au premier plan.
class PurgeCheckStorage {
  static const String _key = 'purge.last_check_timestamp';

  Future<DateTime?> loadLastCheck() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? ms = prefs.getInt(_key);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> saveLastCheck(DateTime timestamp) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, timestamp.millisecondsSinceEpoch);
  }
}
