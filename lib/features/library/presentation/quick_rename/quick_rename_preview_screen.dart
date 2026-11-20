import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/quick_rename_service.dart';

/// Aperçu du renommage rapide : ce qui va changer, avant toute écriture.
/// Se ferme avec le nombre de titres modifiés (`int`) après « Appliquer », ou
/// avec `null` si l'utilisateur annule.
class QuickRenamePreviewScreen extends ConsumerStatefulWidget {
  const QuickRenamePreviewScreen({super.key, required this.plan});

  final QuickRenamePlan plan;

  @override
  ConsumerState<QuickRenamePreviewScreen> createState() => _QuickRenamePreviewScreenState();
}

class _QuickRenamePreviewScreenState extends ConsumerState<QuickRenamePreviewScreen> {
  bool _applying = false;
  String? _error;

  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final int count = await ref.read(quickRenameServiceProvider).apply(widget.plan);
      if (mounted) Navigator.of(context).pop(count);
    } catch (error) {
      // Transaction annulée par le dépôt : rien n'a été écrit, on peut réessayer.
      if (mounted) {
        setState(() {
          _applying = false;
          _error = 'Le renommage a échoué, rien n\'a été modifié : $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final QuickRenamePlan plan = widget.plan;
    final ThemeData theme = Theme.of(context);
    final int renamed = plan.items.length;
    final int unchanged = plan.unchangedCount;

    return PopScope(
      // Pas de retour pendant l'écriture : la transaction doit aller au bout.
      canPop: !_applying,
      child: Scaffold(
        appBar: AppBar(title: const Text('Renommage rapide')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$renamed titre${renamed > 1 ? 's' : ''} renommé${renamed > 1 ? 's' : ''}'
                    ' · $unchanged inchangé${unchanged > 1 ? 's' : ''}',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pas d\'annulation : garde le fichier JSON d\'origine — '
                    'le réimporter rétablit les anciens titres et artistes.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                  ],
                ],
              ),
            ),
            if (_applying) const LinearProgressIndicator(),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: plan.items.length,
                itemBuilder: (context, index) => _ChangeTile(item: plan.items[index]),
              ),
            ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _applying ? null : () => Navigator.of(context).pop(),
                      child: const Text('Annuler'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _applying ? null : _apply,
                      child: const Text('Appliquer'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une ligne : l'ancien « titre — artiste » grisé et barré, le nouveau dessous.
class _ChangeTile extends StatelessWidget {
  const _ChangeTile({required this.item});

  final QuickRenameItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text(
        '${item.oldTitle} — ${item.oldArtist}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          decoration: TextDecoration.lineThrough,
        ),
      ),
      subtitle: Text(
        '${item.newTitle} — ${item.newArtist}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
    );
  }
}
