class AppConstants {
  static const Duration minTrackDuration = Duration(seconds: 30);

  /// Contact de l'éditeur — affiché dans Paramètres > Légal et exigé par
  /// MusicBrainz dans le User-Agent. À compléter avant publication.
  static const String contactEmail = '[Adresse e-mail de contact]';

  /// Build destiné à Google Play : `flutter build apk --dart-define=PLAY_STORE=true`.
  /// Play interdit l'auto-mise à jour hors Play Store : le bouton "Mise à
  /// jour APK" est masqué et android/app/build.gradle.kts retire la
  /// permission REQUEST_INSTALL_PACKAGES du manifeste de ce build.
  static const bool playStoreBuild = bool.fromEnvironment('PLAY_STORE');
}
