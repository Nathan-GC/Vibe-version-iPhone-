# Tests d'intégration (recette sur émulateur Android)

Hors de la suite `flutter test` (qui ne lit que `test/`) : ces suites tournent sur
un vrai appareil ou l'AVD `Vibe_QA_Fresh`, avec le vrai moteur audio, le vrai
FFmpeg et le vrai stockage. `integration_test` est une dépendance de dev :
rien de ce dossier n'entre dans l'APK.

| Suite | Axe | Prérequis |
|---|---|---|
| `navigation_test.dart` | Navigation (N-01..N-06) | aucun (génère ses WAV, base en mémoire) |
| `persistence_test.dart` puis `persistence_restart_test.dart` | Persistance (S-01..S-04, I-01..I-03, W-01) | lancer les deux à la suite, dans deux processus |
| `audio_analysis_test.dart` | FFmpeg hors ligne (A-01..A-06) | fichiers audio poussés par adb dans `<stockage externe de l'app>/qa_audio/` ; mode avion activé par l'hôte |
| `perf_test.dart` | Profilage (P-01..P-05, ~10 min) | build `--profile` ; `qa_audio/a_get_lucky.mp3` et `qa_audio/b_lose_yourself.mp3` ; relevés `dumpsys` côté hôte en parallèle |

Lancement (une suite à la fois) :

```bash
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/navigation_test.dart
```

Ajouter `--profile` pour `perf_test.dart`. Attention : `flutter drive` désinstalle
l'app à la fin, ce qui efface les données de l'app déjà installée sur l'appareil.

Les lignes `QA-…` imprimées par les tests sont les relevés repris dans les
rapports de recette. Sur iOS, ces suites sont gardées identiques pour la parité
du code mais ne sont pas exécutées (pas de simulateur dans ce projet) ; elles
s'appuient sur le stockage externe Android.
