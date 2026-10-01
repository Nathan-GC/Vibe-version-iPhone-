import 'package:dio/dio.dart';

/// Timeouts explicites pour tous les clients Dio de l'app : sans ça, un
/// réseau capricieux (Wi-Fi qui bascule, DNS lent...) laisse une requête
/// pendre indéfiniment côté `dart:io` — sur le terrain, ça se manifestait par
/// des suggestions "qui ne répondent pas" dans l'éditeur de métadonnées sans
/// jamais aboutir à une erreur affichable.
Dio createAppDio() {
  return Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
}
