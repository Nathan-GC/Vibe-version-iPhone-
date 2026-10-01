import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/settings/data/auto_enrich_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('automatic enrichment is on by default', () async {
    expect(await AutoEnrichPreference.isEnabled(), isTrue);
  });

  test('opting out is persisted and read back directly at decision time', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(autoEnrichOnImportProvider.notifier).set(false);

    expect(container.read(autoEnrichOnImportProvider), isFalse);
    expect(await AutoEnrichPreference.isEnabled(), isFalse, reason: 'les imports lisent le réglage enregistré');
  });

  test('a fresh session restores the stored refusal', () async {
    SharedPreferences.setMockInitialValues({'privacy.auto_enrich_on_import': false});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(autoEnrichOnImportProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(autoEnrichOnImportProvider), isFalse);
  });
}
