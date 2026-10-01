import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/storage/scanner/full_device_scan_service.dart';
import '../data/onboarding_providers.dart';

/// Affiché au premier lancement pendant le scan plein-appareil (Étape 8) :
/// indexation en arrière-plan (isolates, voir FullDeviceScanService) le temps
/// que la barre de progression avance, puis redirection automatique vers le
/// lecteur.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runScan());
  }

  Future<void> _runScan() async {
    // Premier scan : iTunes exclusivement, sans aucune question posée à
    // l'utilisateur (voir "Recadrage du Workflow d'Enrichissement" —
    // seul l'enrichissement global explicite, bouton étoile de la
    // Bibliothèque, propose un choix de source).
    await ref.read(onboardingScanControllerProvider.notifier).start();
    if (mounted) context.go('/player');
  }

  @override
  Widget build(BuildContext context) {
    final OnboardingScanState state = ref.watch(onboardingScanControllerProvider);
    final double? progressValue = state.isEnriching
        ? (state.enrichmentTotal > 0 ? state.enrichmentProcessed / state.enrichmentTotal : null)
        : (state.total > 0 ? state.processed / state.total : null);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.library_music_outlined, size: 64),
              const SizedBox(height: 24),
              Text('Bienvenue', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                state.permissionDenied
                    ? 'Permission audio refusée — tu pourras importer tes morceaux manuellement depuis Découverte.'
                    : (state.isEnriching ? 'Enrichissement des morceaux renommés...' : _statusLabel(state)),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              if (!state.permissionDenied) ...[
                LinearProgressIndicator(value: progressValue),
                const SizedBox(height: 8),
                if (state.isEnriching)
                  Text(
                    '${state.enrichmentProcessed}/${state.enrichmentTotal} morceaux enrichis',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else if (state.total > 0)
                  Text('${state.processed}/${state.total} morceaux traités',
                      style: Theme.of(context).textTheme.bodySmall),
                if (state.skippedIncompleteDownloads > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${state.skippedIncompleteDownloads} téléchargement(s) incomplet(s) ignoré(s)',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel(OnboardingScanState state) {
    switch (state.phase) {
      case FullDeviceScanPhase.listingFiles:
        // iOS : seul le dossier de l'app est accessible (Fichiers > Sur mon
        // iPhone > Vibe), pas tout l'appareil — voir DeviceRootResolver.
        return AppPlatform.isIOS
            ? 'Recherche des fichiers audio dans Fichiers › Sur mon iPhone › Vibe...'
            : 'Recherche des fichiers audio sur l\'appareil...';
      case FullDeviceScanPhase.indexing:
        return 'Indexation de ta bibliothèque...';
      case FullDeviceScanPhase.done:
        return 'Bibliothèque prête !';
    }
  }
}
