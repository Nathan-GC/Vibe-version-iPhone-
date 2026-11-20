import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';
import 'package:playlist_app/features/library/presentation/library_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<ProviderContainer> pumpLibrary(WidgetTester tester, {required bool requestBeforeMount}) async {
    final ProviderContainer container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    if (requestBeforeMount) container.read(enrichAllRequestProvider.notifier).request();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: LibraryScreen()),
    ));
    await settle(tester);
    return container;
  }

  testWidgets('demande posée avant le montage : « Enrichir tout » part, puis remise à zéro', (tester) async {
    final ProviderContainer container = await pumpLibrary(tester, requestBeforeMount: true);

    // Bibliothèque vide : « Enrichir tout » répond « Rien à enrichir. » — preuve qu'il a été lancé.
    expect(find.text('Rien à enrichir.'), findsOneWidget);
    expect(container.read(enrichAllRequestProvider), isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('écran déjà monté : la demande est reçue par l\'écoute, une seule fois', (tester) async {
    final ProviderContainer container = await pumpLibrary(tester, requestBeforeMount: false);
    expect(find.text('Rien à enrichir.'), findsNothing);

    container.read(enrichAllRequestProvider.notifier).request();
    await settle(tester);

    expect(find.text('Rien à enrichir.'), findsOneWidget);
    expect(container.read(enrichAllRequestProvider), isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
