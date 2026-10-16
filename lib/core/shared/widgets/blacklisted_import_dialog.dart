import 'package:flutter/material.dart';

import '../../storage/database/app_database.dart';

const String kBlacklistedImportMessage =
    'Ce titre figure actuellement dans votre liste noire. Souhaitez-vous le restaurer dans votre bibliothèque ?';

/// Import manuel d'un titre en liste noire (BlacklistedImportException) :
/// `true` si l'utilisateur choisit de le restaurer, sinon il reste masqué.
Future<bool> confirmRestoreBlacklisted(BuildContext context, BlacklistedTrack entry) async {
  final bool? restore = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('« ${entry.title} »'),
      content: const Text(kBlacklistedImportMessage),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Laisser masqué')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Restaurer')),
      ],
    ),
  );
  return restore == true;
}
