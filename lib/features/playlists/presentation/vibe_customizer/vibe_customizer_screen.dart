import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/platform/gallery_image_picker.dart';
import '../../../../core/storage/database/app_database.dart';
import '../../../../core/theme/vibe_engine/playlist_vibe_resolver.dart';
import '../../../../core/theme/vibe_engine/vibe_engine.dart';
import '../../../../core/theme/vibe_engine/vibe_haptic_service.dart';
import '../../../library/data/library_providers.dart';
import '../../data/playlist_providers.dart';

/// Vibe Engine (Étape 5) : sélection du preset visuel (Layer B) d'une
/// playlist — dégradé de fond du Player et couleur des contrôles (Tab 2).
/// Inclut le Vibe Creator : palette de couleurs et image de fond sur mesure
/// (`VibePreset.custom`).
class VibeCustomizerScreen extends ConsumerWidget {
  const VibeCustomizerScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Playlist?> playlist = ref.watch(playlistByIdProvider(playlistId));

    return Scaffold(
      appBar: AppBar(title: const Text('Vibe')),
      body: playlist.when(
        data: (data) {
          if (data == null) return const SizedBox.shrink();
          final VibePreset current = data.vibeStyle;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ...VibePreset.values.where((preset) => preset != VibePreset.custom).map((preset) {
                final bool isSelected = preset == current;
                // Pochette masquable sur toutes les Vibes (Custom a son
                // propre bloc, voir _CustomVibeEditor) — n'a de sens que
                // pour le preset réellement actif de la playlist.
                final bool showCoverToggle = isSelected;
                // QA Section 2.D : `preset.accentColor` seul devenait invisible
                // pour Space/New OLED (blanc pur) sur une carte à fond clair —
                // bordure de sélection alors indiscernable. Repli sur la
                // couleur primaire du thème (contraste garanti sur
                // `colorScheme.surface`) uniquement quand l'accent ET le fond
                // de carte sont tous deux clairs ; sinon l'accent du preset
                // reste utilisé tel quel (déjà lisible dans ce cas).
                final Color cardSurface = Theme.of(context).colorScheme.surface;
                final Color selectionBorderColor =
                    preset.accentColor.computeLuminance() > 0.5 && cardSurface.computeLuminance() > 0.5
                        ? Theme.of(context).colorScheme.primary
                        : preset.accentColor;
                return Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: isSelected ? BorderSide(color: selectionBorderColor, width: 2) : BorderSide.none,
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: preset.gradientColors),
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(preset.label),
                        trailing: isSelected ? Icon(Icons.check, color: preset.accentColor) : null,
                        onTap: () {
                          VibeHapticService.triggerForPreset(preset, VibeInteraction.vibeSelect);
                          ref.read(playlistRepositoryProvider).updateVibeStyle(playlistId, preset);
                        },
                      ),
                      if (showCoverToggle)
                        SwitchListTile(
                          title: const Text('Afficher la pochette'),
                          value: data.showCoverImage,
                          onChanged: (value) =>
                              ref.read(playlistRepositoryProvider).updateShowCoverImage(playlistId, value),
                        ),
                    ],
                  ),
                );
              }),
              const Divider(height: 32),
              _CustomVibeEditor(playlistId: playlistId, playlist: data),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
    );
  }
}

/// Section "Personnaliser" : jusqu'à 2 couleurs de dégradé au choix, plus une
/// image de fond importée depuis la galerie (`image_picker`). Enregistrer
/// bascule la playlist sur `VibePreset.custom`.
class _CustomVibeEditor extends ConsumerStatefulWidget {
  const _CustomVibeEditor({required this.playlistId, required this.playlist});

  final String playlistId;
  final Playlist playlist;

  @override
  ConsumerState<_CustomVibeEditor> createState() => _CustomVibeEditorState();
}

class _CustomVibeEditorState extends ConsumerState<_CustomVibeEditor> {
  // Section 4.2 "Élargir le nuancier" — 10 teintes historiques + 10
  // supplémentaires ; le code hexadécimal ci-dessous couvre de toute façon
  // n'importe quelle couleur au-delà de ce nuancier.
  static const List<Color> _swatchChoices = [
    Color(0xFFFF3D68),
    Color(0xFFFF8A00),
    Color(0xFFFFE14D),
    Color(0xFF6FCF97),
    Color(0xFF219653),
    Color(0xFF00F0FF),
    Color(0xFF2F80ED),
    Color(0xFF9B51E0),
    Color(0xFFFF00E5),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFF00BFA5),
    Color(0xFFFF6E40),
    Color(0xFFAEEA00),
    Color(0xFFFF4081),
    Color(0xFF40C4FF),
    Color(0xFFFFD700),
    Color(0xFF607D8B),
    Color(0xFF795548),
    Color(0xFFE0E0E0),
  ];

  late List<Color> _selectedColors;
  late Color _selectedAccentColor;
  late VibeCustomEffect _selectedEffect;
  late bool _showCoverImage;
  String? _pendingImagePath;
  bool _clearImage = false;
  String? _pendingVideoPath;
  bool _clearVideo = false;
  bool _isSaving = false;

  final TextEditingController _gradientHexController = TextEditingController();
  final TextEditingController _accentHexController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final VibeVisual current = widget.playlist.resolvedVibe;
    // "Aucune couleur" : liste vide dans l'éditeur (stockée sous forme de
    // sentinelle transparente, voir `kNoVibeColor`).
    _selectedColors = widget.playlist.vibeStyle != VibePreset.custom
        ? [_swatchChoices[0], _swatchChoices[5]]
        : (current.hasNoBackgroundColor ? <Color>[] : List.of(current.gradientColors));
    _selectedAccentColor = current.accentColor;
    _selectedEffect = current.effect;
    _showCoverImage = widget.playlist.showCoverImage;
  }

  @override
  void dispose() {
    _gradientHexController.dispose();
    _accentHexController.dispose();
    super.dispose();
  }

  // Section 4.2 : saisie d'un code hexadécimal ("#RRGGBB" ou "#AARRGGBB",
  // "#" optionnel) — sans alpha, opaque par défaut (AA = FF), cohérent avec
  // les nuances du sélecteur ci-dessus qui sont elles aussi toutes opaques.
  static Color? _parseHex(String input) {
    String hex = input.trim().replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final int? value = int.tryParse(hex, radix: 16);
    return value == null ? null : Color(value);
  }

  void _applyGradientHex() {
    final Color? color = _parseHex(_gradientHexController.text);
    if (color == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code hexadécimal invalide')));
      return;
    }
    _toggleColor(color);
    _gradientHexController.clear();
  }

  void _applyAccentHex() {
    final Color? color = _parseHex(_accentHexController.text);
    if (color == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code hexadécimal invalide')));
      return;
    }
    setState(() => _selectedAccentColor = color);
    _accentHexController.clear();
  }

  /// Option exclusive "Aucune couleur" : vide le dégradé (fond transparent) ;
  /// choisir ensuite une couleur la désélectionne (voir [_toggleColor]).
  void _selectNoColor() => setState(() => _selectedColors = []);

  /// Réordonne les couleurs sélectionnées : l'ordre = l'ordre du dégradé.
  void _reorderColors(int oldIndex, int newIndex) {
    setState(() {
      // Nouvelle liste (jamais de mutation en place) : l'aperçu passe cette
      // instance au LinearGradient, et une liste partagée entre l'ancienne et la
      // nouvelle BoxDecoration les fait juger égales -> pas de repaint.
      final List<Color> reordered = [..._selectedColors];
      reordered.insert(newIndex, reordered.removeAt(oldIndex));
      _selectedColors = reordered;
    });
  }

  void _toggleColor(Color color) {
    setState(() {
      if (_selectedColors.contains(color)) {
        if (_selectedColors.length > 1) _selectedColors = [..._selectedColors]..remove(color);
      } else if (_selectedColors.length < 2) {
        _selectedColors = [..._selectedColors, color];
      } else {
        _selectedColors = [_selectedColors.last, color];
      }
    });
  }

  Future<void> _pickImage() async {
    final XFile? picked = await pickGalleryImage();
    if (picked == null) return;
    setState(() {
      _pendingImagePath = picked.path;
      _clearImage = false;
    });
  }

  /// Section 4.3 : vidéo verticale courte jouée en boucle à la place des
  /// shaders — voir MasterPlayerScreen/VibeVideoBackground.
  Future<void> _pickVideo() async {
    final XFile? picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _pendingVideoPath = picked.path;
      _clearVideo = false;
    });
  }

  /// Supprime (au mieux) un ancien fond, uniquement s'il vit dans le dossier
  /// `vibe_backgrounds` de l'app — jamais un fichier externe.
  Future<void> _deleteOwnedBackground(String path) async {
    if (path.isEmpty || !path.split(RegExp(r'[\\/]')).contains('vibe_backgrounds')) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Fichier verrouillé ou déjà supprimé : sans conséquence.
    }
  }

  Future<void> _save() async {
    VibeHapticService.triggerForPreset(VibePreset.custom, VibeInteraction.vibeSelect);
    setState(() => _isSaving = true);
    try {
      String backgroundVideoPath = widget.playlist.customBackgroundVideoPath;
      if (_clearVideo) {
        backgroundVideoPath = '';
      } else if (_pendingVideoPath != null) {
        final File imported = await ref
            .read(storageManagerServiceProvider)
            .importVibeBackgroundVideo(File(_pendingVideoPath!), widget.playlistId);
        backgroundVideoPath = imported.path;
      }

      String backgroundImagePath = widget.playlist.customBackgroundImagePath;
      if (_clearImage) {
        backgroundImagePath = '';
      } else if (_pendingImagePath != null) {
        final File imported = await ref
            .read(storageManagerServiceProvider)
            .importVibeBackgroundImage(File(_pendingImagePath!), widget.playlistId);
        backgroundImagePath = imported.path;
      }

      await ref.read(playlistRepositoryProvider).updateCustomVibe(
            widget.playlistId,
            colors: _selectedColors.isEmpty ? const [kNoVibeColor] : _selectedColors,
            accentColor: _selectedAccentColor,
            backgroundImagePath: backgroundImagePath,
            effect: _selectedEffect,
            backgroundVideoPath: backgroundVideoPath,
          );
      // Fond retiré : la base ne le référence plus, on libère le fichier.
      if (_clearVideo) await _deleteOwnedBackground(widget.playlist.customBackgroundVideoPath);
      if (_clearImage) await _deleteOwnedBackground(widget.playlist.customBackgroundImagePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vibe personnalisée appliquée')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasExistingImage =
        !_clearImage && _pendingImagePath == null && widget.playlist.customBackgroundImagePath.isNotEmpty;
    final bool hasExistingVideo =
        !_clearVideo && _pendingVideoPath == null && widget.playlist.customBackgroundVideoPath.isNotEmpty;
    final bool isCustomActive = widget.playlist.vibeStyle == VibePreset.custom;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isCustomActive ? BorderSide(color: _selectedAccentColor, width: 2) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Personnaliser', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (isCustomActive) const Icon(Icons.check_circle, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                // LinearGradient exige au moins 2 couleurs : "Aucune couleur"
                // s'affiche transparent, une couleur seule en aplat.
                gradient: LinearGradient(
                  colors: _selectedColors.isEmpty
                      ? const [kNoVibeColor, kNoVibeColor]
                      : (_selectedColors.length == 1 ? [..._selectedColors, ..._selectedColors] : _selectedColors),
                ),
                image: hasExistingImage || _pendingImagePath != null
                    ? DecorationImage(
                        image: _pendingImagePath != null
                            ? FileImage(File(_pendingImagePath!))
                            : FileImage(File(widget.playlist.customBackgroundImagePath)) as ImageProvider,
                        fit: BoxFit.cover,
                        opacity: 0.85,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            Text('Couleurs du dégradé (2 max)', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Semantics(
              button: true,
              selected: _selectedColors.isEmpty,
              label: 'Aucune couleur : fond transparent',
              excludeSemantics: true,
              onTap: _selectNoColor,
              child: ChoiceChip(
                avatar: const Icon(Icons.format_color_reset_outlined, size: 18),
                label: const Text('Aucune couleur'),
                selected: _selectedColors.isEmpty,
                onSelected: (_) => _selectNoColor(),
              ),
            ),
            const SizedBox(height: 8),
            if (_selectedColors.length == 2) ...[
              Text('Ordre du dégradé (appui long, puis glisser)', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              SizedBox(
                height: 44,
                width: 2 * 44.0 + 8,
                child: ReorderableListView(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  onReorderItem: _reorderColors,
                  children: [
                    for (int i = 0; i < _selectedColors.length; i++)
                      ReorderableDelayedDragStartListener(
                        // Clé stable par couleur (jamais deux fois la même, voir
                        // [_toggleColor]) : l'index changerait à chaque déplacement.
                        key: ValueKey(_selectedColors[i].toARGB32()),
                        index: i,
                        child: Semantics(
                          label: 'Couleur ${i + 1} sur 2 du dégradé, appui long puis glisser pour réordonner',
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _selectedColors[i],
                                shape: BoxShape.circle,
                                border: Border.all(color: Theme.of(context).colorScheme.onSurface, width: 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _swatchChoices.map((color) {
                final bool selected = _selectedColors.contains(color);
                return GestureDetector(
                  onTap: () => _toggleColor(color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: selected
                        ? Icon(Icons.check,
                            size: 16, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            _HexColorInput(controller: _gradientHexController, onSubmit: _applyGradientHex),
            const SizedBox(height: 16),
            Text('Couleur d\'accentuation (boutons, contrôles)', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _swatchChoices.map((color) {
                final bool selected = color == _selectedAccentColor;
                return GestureDetector(
                  onTap: () => setState(() => _selectedAccentColor = color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: selected
                        ? Icon(Icons.check,
                            size: 16, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            _HexColorInput(controller: _accentHexController, onSubmit: _applyAccentHex),
            const SizedBox(height: 16),
            Text('Effet de fond', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            SegmentedButton<VibeCustomEffect>(
              segments: const [
                ButtonSegment(value: VibeCustomEffect.fluid, label: Text('Fluide')),
                ButtonSegment(value: VibeCustomEffect.animatedGradient, label: Text('Dégradé animé')),
                ButtonSegment(value: VibeCustomEffect.radiation, label: Text('Radiation')),
              ],
              selected: {_selectedEffect},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => setState(() => _selectedEffect = selection.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Afficher la pochette'),
              value: _showCoverImage,
              onChanged: (value) {
                setState(() => _showCoverImage = value);
                ref.read(playlistRepositoryProvider).updateShowCoverImage(widget.playlistId, value);
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Image de fond'),
                ),
                if (hasExistingImage || _pendingImagePath != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Retirer l\'image',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _pendingImagePath = null;
                      _clearImage = true;
                    }),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pickVideo,
                  icon: const Icon(Icons.videocam_outlined),
                  label: const Text('Ajouter une vidéo'),
                ),
                if (hasExistingVideo || _pendingVideoPath != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Retirer la vidéo',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _pendingVideoPath = null;
                      _clearVideo = true;
                    }),
                  ),
                ],
              ],
            ),
            if (hasExistingVideo || _pendingVideoPath != null) ...[
              const SizedBox(height: 4),
              Text(
                'Une vidéo de fond remplace l\'effet/l\'image ci-dessus dans le Lecteur tant qu\'elle reste définie.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _isSaving ? null : _save,
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Appliquer la Vibe personnalisée'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Champ de saisie hexadécimale (Section 4.2) partagé par le dégradé et
/// l'accent — "#" optionnel, complète automatiquement sans canal alpha
/// explicite ("#RRGGBB") en couleur opaque (voir `_parseHex`).
class _HexColorInput extends StatelessWidget {
  const _HexColorInput({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Code hexadécimal',
              hintText: '#FF5733',
              isDense: true,
              prefixIcon: Icon(Icons.tag, size: 18),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: onSubmit, child: const Text('Ajouter')),
      ],
    );
  }
}
