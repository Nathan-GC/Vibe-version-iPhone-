import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio_engine/player_controller.dart';
import '../../../core/theme/vibe_engine/vibe_haptic_service.dart';

/// Barre de progression interactive (Étape 3), reliée à `just_audio` via
/// `PlayerController.seek`. `fallbackDuration` (Tracks.durationSeconds) évite
/// un slider bloqué à `max: 0` le temps que `durationStream` émette sa
/// première valeur au chargement d'une piste.
class ProgressSlider extends ConsumerStatefulWidget {
  const ProgressSlider({super.key, required this.fallbackDuration, required this.color});

  final Duration fallbackDuration;
  final Color color;

  @override
  ConsumerState<ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends ConsumerState<ProgressSlider> {
  // Non-null pendant un drag : la valeur affichée suit le doigt plutôt que le
  // flux de position réel, resynchronisé seulement au relâchement (onChangeEnd).
  double? _dragValueMs;

  @override
  Widget build(BuildContext context) {
    final Duration position = ref.watch(positionStreamProvider).value ?? Duration.zero;
    final Duration? liveDuration = ref.watch(durationStreamProvider).value;
    final Duration duration =
        (liveDuration == null || liveDuration == Duration.zero) ? widget.fallbackDuration : liveDuration;

    final double maxMs = duration.inMilliseconds.toDouble().clamp(1, double.infinity);
    final double valueMs = (_dragValueMs ?? position.inMilliseconds.toDouble()).clamp(0, maxMs);

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: widget.color,
            thumbColor: widget.color,
            overlayColor: widget.color.withValues(alpha: 0.2),
            inactiveTrackColor: widget.color.withValues(alpha: 0.25),
          ),
          child: Slider(
            value: valueMs,
            max: maxMs,
            onChanged: (value) => setState(() => _dragValueMs = value),
            onChangeEnd: (value) {
              VibeHapticService.trigger(context, VibeInteraction.seek);
              ref.read(playerControllerProvider.notifier).seek(Duration(milliseconds: value.round()));
              setState(() => _dragValueMs = null);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // QA Section 2.B : explicitement teintées à `widget.color`
              // (vibe.accentColor) — laissées au style ambiant par défaut,
              // elles restaient illisibles sur les Vibes sombres (ex. Space,
              // New OLED) dont le thème Material de base n'a pas de rapport
              // avec la palette de la Vibe active.
              Text(
                _format(Duration(milliseconds: valueMs.round())),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: widget.color),
              ),
              Text(_format(duration), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: widget.color)),
            ],
          ),
        ),
      ],
    );
  }

  String _format(Duration d) {
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
