import 'package:shared_preferences/shared_preferences.dart';

class PersistedPlayerState {
  const PersistedPlayerState({required this.queueTrackIds, required this.currentIndex, this.currentPlaylistId});

  final List<String> queueTrackIds;
  final int currentIndex;
  // Bug critique QA (Vibe Engine après redémarrage à froid) : absent jusqu'ici
  // de la persistance, donc toujours `null` après `_restoreLastSession` —
  // MasterPlayerScreen/activeVibeProvider retombaient alors indéfiniment sur
  // leur repli neutre (dégradé gris, accentColor black87) après un force-stop/
  // relance, jamais sur la Vibe réelle de la playlist en cours.
  final String? currentPlaylistId;
}

/// Persiste la queue + l'index courant (+ la playlist active, voir
/// [PersistedPlayerState.currentPlaylistId]) pour reprendre au début du
/// dernier morceau actif au lancement (Étape 5 — "State Retention"). Écrit à
/// chaque changement de piste/pause plutôt qu'à un hook de fermeture précis :
/// le process peut être tué par l'OS à tout moment sur mobile.
class PlayerStateStorage {
  static const String _keyQueueIds = 'player.queue_track_ids';
  static const String _keyCurrentIndex = 'player.current_index';
  static const String _keyPlaylistId = 'player.current_playlist_id';

  Future<void> save({required List<String> queueTrackIds, required int currentIndex, String? currentPlaylistId}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyQueueIds, queueTrackIds);
    await prefs.setInt(_keyCurrentIndex, currentIndex);
    if (currentPlaylistId == null) {
      await prefs.remove(_keyPlaylistId);
    } else {
      await prefs.setString(_keyPlaylistId, currentPlaylistId);
    }
  }

  Future<PersistedPlayerState?> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? ids = prefs.getStringList(_keyQueueIds);
    final int? index = prefs.getInt(_keyCurrentIndex);
    if (ids == null || ids.isEmpty || index == null) return null;
    return PersistedPlayerState(
      queueTrackIds: ids,
      currentIndex: index,
      currentPlaylistId: prefs.getString(_keyPlaylistId),
    );
  }
}
