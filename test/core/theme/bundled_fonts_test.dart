import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // google_fonts ne cherche en local que `<Famille>-<Graisse>.ttf` : un nom
  // différent ferait retomber silencieusement sur la police système, le
  // téléchargement au lancement étant désactivé (main.dart).
  test('every Outfit weight used by the theme is bundled, with its OFL licence', () async {
    final List<String> assets = (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets();

    for (final String weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      expect(assets, contains('assets/fonts/Outfit-$weight.ttf'));
    }
    expect(assets, contains('assets/fonts/OFL.txt'));
  });
}
