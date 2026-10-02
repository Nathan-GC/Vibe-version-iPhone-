import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/shared/onboarding_storage.dart';
import '../../../core/theme/global_theme/global_theme.dart';
import '../../../core/theme/vibe_engine/active_vibe_provider.dart' show defaultVibeFor;
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../../settings/presentation/legal_screen.dart';

/// Appelé par main.dart avant tout le reste de l'app : tant que les textes en
/// vigueur n'ont pas été acceptés (premier lancement, ou mise à jour depuis
/// une version sans consentement ou aux textes plus anciens), seul cet écran
/// plein écran est affiché — ni lecteur (restauration du dernier titre et de
/// sa pochette en ligne), ni notification média, ni aucun appel réseau. Se
/// termine une fois l'acceptation enregistrée, immédiatement si elle l'était.
Future<void> runLegalConsentGate(ProviderContainer container, {void Function(Widget app) show = runApp}) async {
  final OnboardingStorage storage = OnboardingStorage();
  if (await storage.acceptedLegalVersion() == LegalScreen.lastUpdated) return;

  final String title = await storage.isFirstLaunch() ? 'Bienvenue sur Vibe' : 'Conditions mises à jour';
  final Completer<void> accepted = Completer<void>();
  show(UncontrolledProviderScope(
    container: container,
    child: _LegalConsentApp(
      title: title,
      onAccept: () {
        if (!accepted.isCompleted) accepted.complete();
      },
    ),
  ));
  await accepted.future;
  await storage.acceptLegal(LegalScreen.lastUpdated);
}

/// Thème de l'utilisateur (mode, couleur) sans la Vibe de la playlist en
/// cours, qui supposerait le lecteur déjà initialisé.
class _LegalConsentApp extends ConsumerWidget {
  const _LegalConsentApp({required this.title, required this.onAccept});

  final String title;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color accent = ref.watch(userAccentColorProvider);
    final VibeVisual vibe = defaultVibeFor(accent);
    return MaterialApp(
      title: 'Vibe',
      debugShowCheckedModeBanner: false,
      themeMode: ref.watch(globalThemeModeProvider),
      theme: applyVibe(buildLightTheme(seedColor: accent), vibe),
      darkTheme: applyVibe(buildDarkTheme(seedColor: accent), vibe),
      home: Scaffold(
        body: SafeArea(child: Center(child: _LegalConsentBody(title: title, onAccept: onAccept))),
      ),
    );
  }
}

/// Acceptation des conditions d'utilisation et de la politique de
/// confidentialité, avec accès direct aux deux textes (page Légal, document
/// déjà déplié).
class _LegalConsentBody extends StatelessWidget {
  const _LegalConsentBody({required this.title, required this.onAccept});

  final String title;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.library_music_outlined, size: 64),
          const SizedBox(height: 24),
          Text(title, style: text.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text(
            'Avant de continuer, prenez connaissance des conditions d\'utilisation et de la politique de '
            'confidentialité de l\'application (version du ${LegalScreen.lastUpdated}) :',
            textAlign: TextAlign.center,
            style: text.bodyMedium,
          ),
          const SizedBox(height: 8),
          for (final String document in const [LegalScreen.terms, LegalScreen.privacy])
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (context) => LegalScreen(openDocument: document)),
              ),
              child: Text(document),
            ),
          const SizedBox(height: 16),
          Text(
            'En appuyant sur « Accepter et continuer », vous acceptez ces conditions et cette politique.',
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onAccept, child: const Text('Accepter et continuer')),
        ],
      ),
    );
  }
}
