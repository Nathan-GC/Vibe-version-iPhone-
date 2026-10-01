import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playlist_app/app/app.dart';

void main() {
  testWidgets('App boots and shows the bottom navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PlaylistApp()));
    await tester.pump();

    expect(find.text('Lecteur'), findsOneWidget);
  });
}
