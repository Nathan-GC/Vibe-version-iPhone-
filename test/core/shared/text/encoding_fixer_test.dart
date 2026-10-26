import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/shared/text/encoding_fixer.dart';

void main() {
  group('EncodingFixer.fix', () {
    test('repairs "BeyoncÇ" to "Beyoncé"', () {
      expect(EncodingFixer.fix('BeyoncÇ'), 'Beyoncé');
    });

    test('repairs the ROSAL÷A exception to "ROSALíA"', () {
      expect(EncodingFixer.fix('ROSAL÷A'), 'ROSALíA');
    });

    test('repairs "crÇature avait ses raisons"', () {
      expect(EncodingFixer.fix('crÇature avait ses raisons'), 'créature avait ses raisons');
    });

    test('leaves "áa n\'en vaut pas la peine" unchanged: "á" alone is not a signature (known limitation)', () {
      expect(EncodingFixer.fix("áa n'en vaut pas la peine"), "áa n'en vaut pas la peine");
    });

    test('converts the whole string once a signature is present', () {
      expect(EncodingFixer.fix('BeyoncÇ - áa'), 'Beyoncé - ça');
    });

    test('leaves correctly encoded text unchanged', () {
      expect(EncodingFixer.fix('Beyoncé'), 'Beyoncé');
      expect(EncodingFixer.fix('Angèle'), 'Angèle');
      expect(EncodingFixer.fix('Don’t Stop – Remix'), 'Don’t Stop – Remix');
    });
  });
}
