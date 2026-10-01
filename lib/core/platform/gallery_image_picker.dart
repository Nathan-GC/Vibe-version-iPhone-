import 'package:image_picker/image_picker.dart';

import 'app_platform.dart';

/// Choix d'une image dans la galerie (pochette de morceau/playlist, fond de
/// Vibe) — point unique des 4 écrans concernés.
///
/// iOS : `requestFullMetadata: false` fait passer `image_picker` par
/// PHPicker SANS demande d'accès à toute la photothèque (l'app ne lit
/// jamais les métadonnées EXIF, elle copie seulement l'image choisie).
/// Android : appel strictement identique à l'historique
/// (`requestFullMetadata` à sa valeur par défaut, `true`).
Future<XFile?> pickGalleryImage() {
  return ImagePicker().pickImage(
    source: ImageSource.gallery,
    imageQuality: 90,
    requestFullMetadata: !AppPlatform.isIOS,
  );
}
