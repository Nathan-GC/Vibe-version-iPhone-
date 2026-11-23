import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/identity/track_match_key.dart' show foldDiacritics;
import '../../../../core/storage/scanner/importable_audio_finder.dart';

/// Résultat renvoyé (Navigator.pop) par [ImportableAudioScreen] ; `null` =
/// retour sans rien choisir.
sealed class ImportableAudioResult {
  const ImportableAudioResult();
}

/// Fichiers cochés, dans l'ordre de la liste (plus récents d'abord).
class ImportableAudioPicked extends ImportableAudioResult {
  const ImportableAudioPicked(this.paths);

  final List<String> paths;
}

/// « Parcourir les dossiers… » : l'appelant ouvre le sélecteur système.
class ImportableAudioBrowse extends ImportableAudioResult {
  const ImportableAudioBrowse();
}

/// Import manuel : fichiers audio du téléphone pas encore en bibliothèque,
/// plus récents d'abord, à cocher puis importer d'un coup.
class ImportableAudioScreen extends ConsumerStatefulWidget {
  const ImportableAudioScreen({super.key, this.clock = DateTime.now});

  /// Horloge injectable : « aujourd'hui »/« hier » dépendent de la date du jour.
  final DateTime Function() clock;

  @override
  ConsumerState<ImportableAudioScreen> createState() => _ImportableAudioScreenState();
}

class _ImportableAudioScreenState extends ConsumerState<ImportableAudioScreen> {
  List<ImportableAudioFile>? _files;
  // Noms repliés (minuscules, sans accents) calculés une fois au chargement :
  // la liste peut compter des milliers de fichiers, refiltrée à chaque frappe.
  List<String> _foldedNames = const [];
  Object? _error;
  String _query = '';
  // Par chemin, hors de la liste filtrée : la sélection survit à la recherche.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<ImportableAudioFile> files = await ref.read(importableAudioFinderProvider).find();
      if (!mounted) return;
      setState(() {
        _files = files;
        _foldedNames = [for (final ImportableAudioFile file in files) foldDiacritics(file.name)];
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _toggle(String path, bool selected) {
    setState(() => selected ? _selected.add(path) : _selected.remove(path));
  }

  void _import() {
    final List<ImportableAudioFile> files = _files ?? const [];
    Navigator.of(context).pop(
      ImportableAudioPicked([
        for (final ImportableAudioFile file in files)
          if (_selected.contains(file.path)) file.path,
      ]),
    );
  }

  void _browse() => Navigator.of(context).pop(const ImportableAudioBrowse());

  @override
  Widget build(BuildContext context) {
    final List<ImportableAudioFile>? files = _files;
    final bool isEmpty = files != null && files.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Importer des fichiers audio')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody(files)),
            if (!isEmpty) _buildActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(List<ImportableAudioFile>? files) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Recherche impossible : $_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _browse, child: const Text('Parcourir les dossiers…')),
            ],
          ),
        ),
      );
    }
    if (files == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Recherche des fichiers audio du téléphone…'),
          ],
        ),
      );
    }
    if (files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Aucun nouveau fichier audio sur le téléphone.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _browse, child: const Text('Parcourir les dossiers…')),
            ],
          ),
        ),
      );
    }

    final String folded = foldDiacritics(_query.trim());
    final List<ImportableAudioFile> visible = [
      for (int i = 0; i < files.length; i++)
        if (folded.isEmpty || _foldedNames[i].contains(folded)) files[i],
    ];
    final DateTime now = widget.clock();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Rechercher un fichier',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('Aucun fichier ne correspond.'))
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final ImportableAudioFile file = visible[index];
                    return CheckboxListTile(
                      value: _selected.contains(file.path),
                      onChanged: (value) => _toggle(file.path, value ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${file.folder.isEmpty ? 'Stockage interne' : file.folder} · ${formatImportableDate(file.modified, now)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _selected.isEmpty ? null : _import,
              child: Text('Importer (${_selected.length})'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(onPressed: _browse, child: const Text('Parcourir les dossiers…')),
          ),
        ],
      ),
    );
  }
}

const List<String> _months = [
  'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.', //
];

/// « aujourd'hui 14:32 », « hier 09:10 », sinon « 12 nov. 2026 ». Petit
/// formateur maison : `intl` n'est pas une dépendance directe de l'app.
String formatImportableDate(DateTime date, DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(date.year, date.month, date.day);
  final int daysAgo = today.difference(day).inDays;
  final String time = '${two(date.hour)}:${two(date.minute)}';
  if (daysAgo == 0) return "aujourd'hui $time";
  if (daysAgo == 1) return 'hier $time';
  return '${date.day} ${_months[date.month - 1]} ${date.year}';
}
