import 'dart:io';

/// Debug uniquement : `network_security_config.xml` ne couvre que la pile
/// réseau native Android (WebView, OkHttp...) — le `HttpClient` de dart:io
/// utilisé par Dio embarque son propre magasin de certificats racine
/// (BoringSSL) et ignore complètement le magasin système/utilisateur
/// Android, CA installés par l'utilisateur compris. Sans ceci, un proxy
/// TLS de développement (ex. antivirus interceptant HTTPS) fait échouer
/// tous les appels réseau de l'app avec `CERTIFICATE_VERIFY_FAILED` même
/// après avoir installé son certificat côté Android. Jamais actif en
/// release — voir l'appel gardé par `kDebugMode` dans main.dart.
class DevHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}
