import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/storage/database/library_category.dart';
import '../../../../core/storage/database/track_repository.dart';
import '../../data/library_providers.dart';
import '../../data/quick_rename_service.dart';
import 'quick_rename_preview_screen.dart';

/// Renommage rapide de « Tous les titres importés » :
///  1. fenêtre d'explication (avec la consigne à copier pour une IA) ;
///  2. choix du `.json` corrigé, analyse (refus = message tel quel) ;
///  3. écran d'aperçu, puis application ;
///  4. proposition de réenrichir les titres renommés, qui lance « Enrichir tout »
///     depuis la Bibliothèque (voir [enrichAllRequestProvider]).
///
/// Les fichiers audio ne sont jamais modifiés : seuls titre et artiste changent
/// dans l'app.
class QuickRenameFlow {
  const QuickRenameFlow._();

  /// Texte prêt à coller dans une IA, avec le JSON exporté.
  static const String aiPrompt = 'Corrige les champs title et artist de chaque titre de ce JSON (orthographe, casse, '
      'artiste principal, featurings écrits "feat. X" dans artist). Ne modifie rien d\'autre : ni l\'ordre, ni les id, '
      'ni album, ni les autres clés. Rends uniquement le JSON complet, sans texte autour.';

  static Future<void> run(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final GoRouter router = GoRouter.of(context);
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);

    final bool? go = await showDialog<bool>(context: context, builder: (_) => const _ExplanationDialog());
    if (go != true) return;

    final PlatformFile? picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
    final String? path = picked?.path;
    if (path == null) return;

    final String text;
    try {
      text = await File(path).readAsString();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Lecture du fichier impossible : $error')));
      return;
    }
    if (!context.mounted) return;

    final QuickRenameAnalysis analysis = await ref.read(quickRenameServiceProvider).analyze(text);
    if (!context.mounted) return;
    switch (analysis) {
      case QuickRenameFailure(:final String message):
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Fichier refusé'),
            content: SingleChildScrollView(child: Text(message)),
            actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
          ),
        );
      case QuickRenameSuccess(:final QuickRenamePlan plan):
        if (plan.items.isEmpty) {
          final int same = plan.unchangedCount;
          messenger.showSnackBar(
            SnackBar(content: Text('Aucun changement : $same titre${same > 1 ? 's' : ''} identique${same > 1 ? 's' : ''}.')),
          );
          return;
        }
        final int? renamed = await navigator.push<int>(
          MaterialPageRoute<int>(builder: (_) => QuickRenamePreviewScreen(plan: plan)),
        );
        if (renamed == null) return; // Aperçu annulé : rien n'a été écrit.
        messenger.showSnackBar(
          SnackBar(content: Text('$renamed titre${renamed > 1 ? 's' : ''} renommé${renamed > 1 ? 's' : ''}.')),
        );
        if (!context.mounted) return;
        await _proposeReenrichment(context, ref, router, [for (final QuickRenameItem i in plan.items) i.trackId]);
    }
  }

  /// Fenêtre « Réenrichir ? » : les métadonnées en ligne (album, année,
  /// pochette, genre) viennent encore de l'ancien nom.
  static Future<void> _proposeReenrichment(
    BuildContext context,
    WidgetRef ref,
    GoRouter router,
    List<String> ids,
  ) async {
    final int n = ids.length;
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Réenrichir ${n > 1 ? 'les $n titres renommés' : 'le titre renommé'} ?'),
        content: Text(
          'L\'album, l\'année, la pochette et le genre ${n > 1 ? 'de ces titres viennent' : 'de ce titre viennent'} '
          'encore de l\'ancien nom. Le réenrichissement les remplace par ceux trouvés en ligne pour le nouveau nom '
          'quand la correspondance est fiable ; sinon ils restent tels quels. Une connexion est nécessaire.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Plus tard')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Réenrichir')),
        ],
      ),
    );
    // `ref` appartient à la carte de playlist qui a lancé le flux : plus
    // utilisable si elle a disparu pendant la fenêtre.
    if (proceed != true || !context.mounted) return;

    await ref.read(trackRepositoryProvider).markForReenrichment(ids);

    // Requête posée AVANT la navigation : la Bibliothèque (route poussée, donc
    // montée à neuf) la consomme à son premier cadre ; si elle était déjà
    // montée, son écoute la reçoit. Filtre « À enrichir » pour voir la file.
    final LibraryFilterController filter = ref.read(libraryFilterProvider.notifier);
    if (ref.read(libraryFilterProvider).category != LibraryCategory.toEnrich) {
      filter.toggleCategory(LibraryCategory.toEnrich);
    }
    ref.read(enrichAllRequestProvider.notifier).request();
    router.push('/space/library');
  }
}

class _ExplanationDialog extends StatelessWidget {
  const _ExplanationDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Renommage rapide'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Exporte « Tous les titres importés » en JSON.'),
            const SizedBox(height: 8),
            const Text(
              '2. Fais corriger le fichier (par exemple par une IA) en ne modifiant QUE « title » et « artist » : '
              'ni l\'ordre, ni les « id », ni le reste.',
            ),
            const SizedBox(height: 8),
            const Text('3. Importe ici le fichier corrigé.'),
            const SizedBox(height: 12),
            Text(
              'Les fichiers audio ne sont pas modifiés : seuls le titre et l\'artiste changent dans l\'app.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copier la consigne pour l\'IA'),
              onPressed: () async {
                final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(const ClipboardData(text: QuickRenameFlow.aiPrompt));
                messenger.showSnackBar(const SnackBar(content: Text('Consigne copiée.')));
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Choisir le fichier')),
      ],
    );
  }
}
