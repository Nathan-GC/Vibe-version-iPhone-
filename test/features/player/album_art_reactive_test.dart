import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/player/widgets/album_art_reactive.dart';

void main() {
  Widget harness(String? imagePath) => MaterialApp(
        home: Scaffold(body: AlbumArtReactive(imagePath: imagePath, semanticLabel: 'Pochette de Halo')),
      );

  testWidgets('a track without cover exposes a named placeholder to TalkBack', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    await tester.pumpWidget(harness(null));

    expect(find.bySemanticsLabel('Pochette indisponible'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a cover that fails to load (offline, missing file) also gets the named placeholder', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    await tester.pumpWidget(harness('/introuvable/cover.jpg'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.bySemanticsLabel(RegExp('Pochette indisponible')), findsOneWidget);
    semantics.dispose();
  });
}
