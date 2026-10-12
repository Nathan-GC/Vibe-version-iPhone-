import 'dart:async';

/// Flux réactif pour une lecture que Drift ne sait pas surveiller seul
/// (plusieurs requêtes, filtre Dart) : [load] est rejoué à chaque événement
/// de [changes] — typiquement `db.tableUpdates(...)`.
///
/// Une rafale de modifications (scan, "Enrichir tout", changement de piste)
/// ne déclenche jamais plus d'un rechargement en cours + un en attente. Un
/// `await for` sur `tableUpdates` les empilait au contraire une à une : avec
/// une playlist ouverte par carte de Mon espace, chaque mise à jour de
/// `tracks` relançait N rechargements complets en file (Lot 1.1, crash au-delà
/// de ~5 playlists).
Stream<T> watchCoalesced<T>(Stream<Object?> changes, Future<T> Function() load) {
  late final StreamController<T> controller;
  StreamSubscription<Object?>? subscription;
  bool active = true;
  bool loading = false;
  bool dirty = false;

  Future<void> reload() async {
    if (loading) {
      dirty = true;
      return;
    }
    loading = true;
    do {
      dirty = false;
      try {
        final T value = await load();
        if (active) controller.add(value);
      } catch (error, stackTrace) {
        if (active) controller.addError(error, stackTrace);
      }
    } while (dirty && active);
    loading = false;
  }

  controller = StreamController<T>(
    onListen: () {
      // Abonnement AVANT le premier chargement : une écriture survenant
      // pendant celui-ci relance un chargement au lieu d'être perdue.
      subscription = changes.listen((_) => reload());
      reload();
    },
    onCancel: () {
      active = false;
      return subscription?.cancel();
    },
  );
  return controller.stream;
}
