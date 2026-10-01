import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/shared/constants/app_constants.dart';
import '../../../core/theme/design_system/app_spacing.dart';
import '../../../core/theme/global_theme/global_theme.dart';
import '../data/auto_enrich_preference.dart';

/// Accessible depuis les 3 écrans principaux (Découverte, Lecteur, Espace).
/// Section "Apparence" (Design System) : mode clair/sombre/système et
/// couleur principale — voir global_theme.dart pour la persistance.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode themeMode = ref.watch(globalThemeModeProvider);
    final Color accentColor = ref.watch(userAccentColorProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.m),
        children: [
          const _SectionTitle('Apparence'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.m),
            child: Text('Thème'),
          ),
          const SizedBox(height: AppSpacing.s),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
            child: Wrap(
              spacing: AppSpacing.s,
              children: ThemeMode.values.map((mode) {
                return ChoiceChip(
                  label: Text(_themeModeLabel(mode)),
                  avatar: Icon(_themeModeIcon(mode), size: 18),
                  selected: themeMode == mode,
                  onSelected: (_) => ref.read(globalThemeModeProvider.notifier).setThemeMode(mode),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: AppSpacing.l),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.m),
            child: Text('Couleur principale'),
          ),
          const SizedBox(height: AppSpacing.s),
          SizedBox(
            height: 56,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
              scrollDirection: Axis.horizontal,
              itemCount: kAccentColorChoices.length,
              separatorBuilder: (context, index) => const SizedBox(width: AppSpacing.s),
              itemBuilder: (context, index) {
                final Color color = kAccentColorChoices[index];
                final bool selected = color.toARGB32() == accentColor.toARGB32();
                return GestureDetector(
                  onTap: () => ref.read(userAccentColorProvider.notifier).setAccentColor(color),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: selected
                        ? Icon(Icons.check, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
                        : null,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.l),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.s),
          const _SectionTitle('Confidentialité'),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Enrichissement automatique à l\'importation'),
            subtitle: const Text(
              'Après un import, recherche pochette et infos sur iTunes puis MusicBrainz. '
              'Désactivé : l\'import reste 100 % hors-ligne.',
            ),
            value: ref.watch(autoEnrichOnImportProvider),
            onChanged: (value) => ref.read(autoEnrichOnImportProvider.notifier).set(value),
          ),
          const Divider(height: 1),
          // iOS : aucune installation hors App Store/TestFlight/Xcode n'est
          // possible (ni .apk, ni paquet local) — l'entrée APK est remplacée
          // par l'emplacement de la bibliothèque dans l'app Fichiers.
          if (AppPlatform.isIOS) ...[
            const SizedBox(height: AppSpacing.s),
            const _SectionTitle('Maintenance'),
            const ListTile(
              leading: Icon(Icons.folder_open_outlined),
              title: Text('Tes fichiers audio'),
              subtitle: Text(
                'Fichiers › Sur mon iPhone › Vibe (ou Finder sur Mac) : dépose-y tes morceaux, '
                'ils sont ajoutés à la Bibliothèque automatiquement.',
              ),
            ),
            const Divider(height: 1),
          ]
          // Interdit par Google Play (auto-mise à jour hors Play Store), voir
          // AppConstants.playStoreBuild.
          else if (!AppConstants.playStoreBuild) ...[
            const SizedBox(height: AppSpacing.s),
            const _SectionTitle('Maintenance'),
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('Mise à jour de l\'application (APK)'),
              subtitle: const Text('Installer un fichier .apk depuis le stockage local'),
              onTap: () => _updateFromApk(context),
            ),
            const Divider(height: 1),
          ],
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Légal'),
            subtitle: const Text('Confidentialité, conditions, licences'),
            onTap: () => context.push('/settings/legal'),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('À propos'),
            subtitle: Text('Vibe — lecteur local-first'),
          ),
        ],
      ),
    );
  }

  /// Mise à jour locale depuis un APK (Section 6) : le fichier choisi est
  /// ouvert via `open_filex`, qui déclenche l'intent natif ACTION_VIEW
  /// (`application/vnd.android.package-archive`) — c'est l'installeur système
  /// d'Android qui prend le relais depuis là (confirmation utilisateur,
  /// éventuel écran "Autoriser cette source" si REQUEST_INSTALL_PACKAGES
  /// n'a jamais été accordée pour cette app). Base SQLite et fichiers
  /// importés (StorageManagerService) vivent dans le stockage propre à
  /// l'app : une mise à jour standard (même package, même signature) les
  /// préserve nativement, sans action de notre part.
  Future<void> _updateFromApk(BuildContext context) async {
    final List<PlatformFile> picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['apk']);
    final String? path = picked.isEmpty ? null : picked.first.path;
    if (path == null) return;

    final OpenResult result = await OpenFilex.open(path);
    if (!context.mounted || result.type == ResultType.done) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Installation impossible : ${result.message}')),
    );
  }

  String _themeModeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.system => 'Système',
        ThemeMode.light => 'Clair',
        ThemeMode.dark => 'Sombre',
      };

  IconData _themeModeIcon(ThemeMode mode) => switch (mode) {
        ThemeMode.system => Icons.brightness_auto_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.m, 0, AppSpacing.m, AppSpacing.s),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
