import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/platform/app_platform.dart';
import '../core/purge/purge_providers.dart';
import '../core/shared/onboarding_storage.dart';
import '../core/shared/permission_retry.dart';
import '../core/theme/global_theme/global_theme.dart';
import '../core/theme/vibe_engine/active_vibe_provider.dart';
import '../core/theme/vibe_engine/vibe_engine.dart';
import '../features/library/data/documents_sync_controller.dart';
import 'router.dart';

class PlaylistApp extends ConsumerStatefulWidget {
  const PlaylistApp({super.key});

  @override
  ConsumerState<PlaylistApp> createState() => _PlaylistAppState();
}

class _PlaylistAppState extends ConsumerState<PlaylistApp> {
  // iOS : retour au premier plan -> synchronisation du dossier Documents
  // (morceaux déposés entre-temps depuis l'app Fichiers ou le Finder).
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
    if (AppPlatform.isIOS) {
      _lifecycleListener = AppLifecycleListener(onResume: _syncDocumentsLibraryIfOnboarded);
    }
    // Demandes de permission après la première frame. Même après la première
    // frame, l'attachement natif de l'Activity Android à permission_handler
    // peut ne pas être terminé (course intermittente, confirmée sur
    // émulateur : passe parfois, échoue parfois avec la même frame) — d'où
    // le retry avec backoff plutôt qu'un simple délai fixe.
    // Repli premier-plan de la purge mensuelle (Étape 7) : le tap sur la
    // notification navigue vers la vue de nettoyage via le routeur global.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Premier lancement : l'onboarding (Étape 8) prend la main pour demander
      // la permission audio et lancer le scan plein-appareil, puis redirige
      // lui-même vers /player une fois l'indexation terminée — la demande de
      // permission générique ci-dessous serait redondante dans ce cas précis,
      // mais notifications locales et vérification de purge restent utiles
      // dès ce premier lancement, donc pas de retour anticipé ici.
      final bool firstLaunch = await OnboardingStorage().isFirstLaunch();
      if (firstLaunch) {
        appRouter.go('/onboarding');
      } else if (AppPlatform.isIOS) {
        // iOS : pas de permission audio (voir OnboardingScanController.start)
        // — à la place, indexation incrémentale des morceaux déposés dans
        // Fichiers > Sur mon iPhone > Vibe, en tâche de fond.
        unawaited(ref.read(documentsSyncControllerProvider.notifier).sync(automatic: true));
      } else {
        await requestPermissionWithRetry(Permission.audio);
      }

      await ref.read(localNotificationServiceProvider).initialize(
            onNotificationTap: () => appRouter.go('/space/cleanup'),
          );
      await ref.read(purgeCheckOnLaunchProvider.future);
    });
  }

  Future<void> _syncDocumentsLibraryIfOnboarded() async {
    // Pendant l'onboarding, c'est son propre scan qui indexe ce dossier.
    if (await OnboardingStorage().isFirstLaunch() || !mounted) return;
    await ref.read(documentsSyncControllerProvider.notifier).sync(automatic: true);
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeMode themeMode = ref.watch(globalThemeModeProvider);
    final VibeVisual vibe = ref.watch(activeVibeProvider);
    final Color userAccent = ref.watch(userAccentColorProvider);

    return MaterialApp.router(
      title: 'Vibe',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: applyVibe(buildLightTheme(seedColor: userAccent), vibe),
      darkTheme: applyVibe(buildDarkTheme(seedColor: userAccent), vibe),
      // Transitions fluides de Vibe (800ms) : `Theme.of(context)` ici est déjà
      // résolu (clair/sombre) par MaterialApp à partir de `theme`/`darkTheme`
      // ci-dessus — `AnimatedTheme` anime la BARRE DE NAVIGATION et le FOND
      // DES CARTES vers cette cible au lieu d'y sauter, pour tout l'arbre en
      // dessous de `child`.
      builder: (context, child) => AnimatedTheme(
        data: Theme.of(context),
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeInOutCubic,
        child: child!,
      ),
      routerConfig: appRouter,
    );
  }
}
