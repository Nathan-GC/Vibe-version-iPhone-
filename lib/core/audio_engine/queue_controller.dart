import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../storage/database/app_database.dart';
import '../storage/database/database_provider.dart';

part 'queue_controller.g.dart';

/// File de lecture en mémoire (liste d'`id` de tracks), distincte du
/// PlayerController pour permettre l'édition de la Queue sans interrompre
/// l'état de lecture en cours.
@riverpod
class QueueController extends _$QueueController {
  /// Ordre avant le passage en mode Aléatoire — permet à [unshuffle] de le
  /// restaurer exactement plutôt que de perdre l'ordre de la playlist
  /// d'origine (voir PlayerRepeatMode dans player_controller.dart).
  List<String>? _preShuffleOrder;

  @override
  List<String> build() => [];

  void addTrackKey(String trackKey) => state = [...state, trackKey];

  void removeAt(int index) => state = [...state]..removeAt(index);

  void reorder(int oldIndex, int newIndex) {
    final List<String> updated = [...state];
    final String item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);
    state = updated;
  }

  /// Remplace intégralement la queue (chargement d'une playlist, restauration
  /// de session au lancement). Efface tout ordre pré-mélange mémorisé : une
  /// toute nouvelle queue n'a pas d'ordre "d'origine" à restaurer.
  void restore(List<String> trackIds) {
    _preShuffleOrder = null;
    state = trackIds;
  }

  /// Mélange la queue courante — [keepFirst], quand fourni (le morceau en
  /// cours de lecture), reste en tête pour que l'index de lecture actif reste
  /// valide (position 0) après le mélange.
  void shuffle({String? keepFirst}) {
    _preShuffleOrder = [...state];
    final List<String> rest = [...state];
    if (keepFirst != null) rest.remove(keepFirst);
    rest.shuffle();
    state = (keepFirst != null && _preShuffleOrder!.contains(keepFirst)) ? [keepFirst, ...rest] : rest;
  }

  /// Restaure l'ordre mémorisé par le dernier [shuffle] — no-op si la queue a
  /// été remplacée entre-temps (voir [restore]).
  void unshuffle() {
    final List<String>? original = _preShuffleOrder;
    if (original == null) return;
    _preShuffleOrder = null;
    state = original;
  }
}

/// Résout les `id` de la queue en [Track] complets, en préservant l'ordre.
final FutureProvider<List<Track>> queueTracksProvider = FutureProvider<List<Track>>((ref) async {
  final List<String> ids = ref.watch(queueControllerProvider);
  if (ids.isEmpty) return const [];

  final AppDatabase db = ref.watch(appDatabaseProvider);
  final List<Track> rows = await (db.select(db.tracks)..where((t) => t.id.isIn(ids))).get();
  final Map<String, Track> byId = {for (final track in rows) track.id: track};

  return [
    for (final id in ids)
      if (byId[id] != null) byId[id]!
  ];
});
