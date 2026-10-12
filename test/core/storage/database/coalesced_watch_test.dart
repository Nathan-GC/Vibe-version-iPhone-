import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/coalesced_watch.dart';

void main() {
  test('a burst of changes during a reload costs one extra reload, not one per change', () async {
    final StreamController<void> changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    int loads = 0;
    final List<int> values = [];
    final StreamSubscription<int> subscription = watchCoalesced<int>(changes.stream, () async {
      loads++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return loads;
    }).listen(values.add);
    addTearDown(subscription.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(values, [1]);

    for (int i = 0; i < 50; i++) {
      changes.add(null);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(loads, 3, reason: 'chargement initial + 1 pour la rafale en cours + 1 pour les changements fusionnés');
    expect(values.last, 3, reason: 'la dernière émission reflète bien l\'état après la rafale');
  });

  test('a change made during the very first load is not lost', () async {
    final StreamController<void> changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    int version = 0;
    final Future<List<int>> firstTwo = watchCoalesced<int>(changes.stream, () async {
      final int seen = version;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return seen;
    }).take(2).toList();

    await Future<void>.delayed(Duration.zero);
    version = 1;
    changes.add(null);

    expect(await firstTwo, [0, 1]);
  });
}
