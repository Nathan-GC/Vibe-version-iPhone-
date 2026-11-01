import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/playlists/data/custom_color_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> newContainer() async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(customColorHistoryProvider);
    // Restauration différée de l'historique enregistré.
    await Future<void>.delayed(Duration.zero);
    return container;
  }

  test('a new colour is added at the head', () async {
    final ProviderContainer c = await newContainer();
    final CustomColorHistory history = c.read(customColorHistoryProvider.notifier);
    await history.add(const Color(0xFF123456));
    await history.add(const Color(0xFF654321));
    expect(c.read(customColorHistoryProvider), [const Color(0xFF654321), const Color(0xFF123456)]);
  });

  test('a duplicate moves back to the head', () async {
    final ProviderContainer c = await newContainer();
    final CustomColorHistory history = c.read(customColorHistoryProvider.notifier);
    await history.add(const Color(0xFF111111));
    await history.add(const Color(0xFF222222));
    await history.add(const Color(0xFF111111));
    expect(c.read(customColorHistoryProvider), [const Color(0xFF111111), const Color(0xFF222222)]);
  });

  test('a fixed swatch is never added', () async {
    final ProviderContainer c = await newContainer();
    await c.read(customColorHistoryProvider.notifier).add(const Color(0xFFFF3D68));
    expect(c.read(customColorHistoryProvider), isEmpty);
  });

  test('the history is capped and the oldest colour drops out', () async {
    final ProviderContainer c = await newContainer();
    final CustomColorHistory history = c.read(customColorHistoryProvider.notifier);
    for (int i = 1; i <= CustomColorHistory.maxLength + 1; i++) {
      await history.add(Color(0xFF000000 + i));
    }
    final List<Color> colors = c.read(customColorHistoryProvider);
    expect(colors.length, CustomColorHistory.maxLength);
    expect(colors.first, Color(0xFF000000 + CustomColorHistory.maxLength + 1));
    expect(colors, isNot(contains(const Color(0xFF000001))));
  });

  test('a new container restores the persisted history', () async {
    final ProviderContainer first = await newContainer();
    await first.read(customColorHistoryProvider.notifier).add(const Color(0xFF123456));

    final ProviderContainer second = await newContainer();
    expect(second.read(customColorHistoryProvider), [const Color(0xFF123456)]);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('vibe.custom_color_history'), ['FF123456']);
  });
}
