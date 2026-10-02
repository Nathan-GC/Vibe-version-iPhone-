import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/storage/scanner/full_device_scan_service.dart';
import '../../library/data/documents_sync_controller.dart';
import '../../settings/data/auto_enrich_preference.dart';
import '../data/onboarding_providers.dart';

/// Premier lancement, une fois les conditions acceptées (étape 1, écran
/// affiché avant l'app — voir runLegalConsentGate), dans cet ordre strict :
/// (2) autorisation des notifications, (3) accès aux fichiers audio, (4)
/// import automatique de l'appareil, (5) enrichissement automatique
/// (seulement si import). Aucun scan ni appel réseau avant (4) et (5).
/// Ensuite : progression du scan plein-appareil (Étape 8), puis lecteur.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final GoRouter router = GoRouter.of(context);
    final OnboardingPermissions permissions = ref.read(onboardingPermissionsProvider);
    await permissions.requestNotifications(onTap: () => router.go('/space/cleanup'));
    final bool audioGranted = await permissions.requestAudio();
    if (!mounted) return;
    if (!audioGranted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Permission audio refusée — vous pourrez importer vos morceaux manuellement depuis Espace → Bibliothèque.',
        ),
      ));
      return _withoutImport();
    }

    final bool import = await _ask(
      // iOS : seul le dossier de l'app est accessible, pas tout l'appareil
      // (voir DeviceRootResolver) — la question le dit.
      AppPlatform.isIOS
          ? 'Souhaitez-vous importer automatiquement tous les titres audio présents dans '
              'Fichiers › Sur mon iPhone › Vibe ?'
          : 'Souhaitez-vous importer automatiquement tous les titres audio présents sur votre appareil ?',
      decline: 'Refuser',
      accept: 'Importer',
    );
    if (!import) return _withoutImport();

    final bool enrich = await _ask(
      'Souhaitez-vous renommer et enrichir automatiquement les pistes importées '
      '(pochettes et métadonnées via iTunes/MusicBrainz) ?',
      decline: 'Non merci',
      accept: 'Activer',
    );
    // Même réglage que Paramètres > Confidentialité, lu par le scan.
    await ref.read(autoEnrichOnImportProvider.notifier).set(enrich);
    if (!mounted) return;

    setState(() => _scanning = true);
    await ref.read(onboardingScanControllerProvider.notifier).start();
    if (mounted) context.go('/player');
  }

  /// Audio refusé (étape 3) ou import refusé (étape 4) : les imports manuels
  /// ultérieurs restent hors-ligne (Paramètres > Confidentialité, réactivable
  /// à tout moment).
  Future<void> _withoutImport() async {
    await ref.read(autoEnrichOnImportProvider.notifier).set(false);
    // iOS (seul le refus de l'étape 4 mène ici) : plus de synchronisation du
    // dossier à l'ouverture, seulement depuis le bouton de la Bibliothèque.
    if (AppPlatform.isIOS) await DocumentsSyncController.disableAutomaticSync();
    await ref.read(onboardingStorageProvider).markCompleted();
    if (mounted) context.go('/player');
  }

  /// Modale des étapes 4 et 5 ; fermée sans réponse (bouton retour) = refus.
  Future<bool> _ask(String question, {required String decline, required String accept}) async {
    if (!mounted) return false;
    final bool? answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(decline)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(accept)),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    // Écran vide sous les demandes des étapes 2 à 5 : rien ne dépasse des
    // modales.
    if (!_scanning) return const Scaffold();

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
                state.isEnriching ? 'Enrichissement des morceaux renommés...' : _statusLabel(state),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
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
        return 'Indexation de votre bibliothèque...';
      case FullDeviceScanPhase.done:
        return 'Bibliothèque prête !';
    }
  }
}
