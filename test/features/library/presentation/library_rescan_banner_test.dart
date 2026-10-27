import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/library/data/library_rescan_providers.dart';
import 'package:playlist_app/features/library/presentation/library_rescan_banner.dart';

void main() {
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: Column(children: [LibraryRescanBanner()]))),
    ));
    return container;
  }

  testWidgets('hidden outside a pass', (tester) async {
    await pump(tester);

    expect(find.textContaining('Mise à jour des métadonnées'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('shows "done / total" with a progress bar during a pass, then disappears', (tester) async {
    final ProviderContainer container = await pump(tester);

    container.read(libraryRescanProgressProvider.notifier).set((done: 120, total: 470));
    await tester.pump();

    expect(find.text('Mise à jour des métadonnées : 120 / 470'), findsOneWidget);
    expect(
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(120 / 470, 1e-9));
    expect(find.bySemanticsLabel('Mise à jour des métadonnées : 120 titres sur 470'), findsOneWidget);

    container.read(libraryRescanProgressProvider.notifier).set(null);
    await tester.pump();

    expect(find.textContaining('Mise à jour des métadonnées'), findsNothing);
  });
}
