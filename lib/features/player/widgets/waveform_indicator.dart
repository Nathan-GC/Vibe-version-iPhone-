import 'package:flutter/material.dart';

/// Équaliseur 4 barres animé, affiché sur l'item actif de la Queue.
class WaveformIndicator extends StatelessWidget {
  const WaveformIndicator({super.key, required this.isPlaying});

  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    if (!isPlaying) return const SizedBox(width: 16, height: 16);
    return SizedBox(
      width: 16,
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(4, (i) => _Bar(delay: i * 100)),
      ),
    );
  }
}

class _Bar extends StatefulWidget {
  const _Bar({required this.delay});

  final int delay;

  @override
  State<_Bar> createState() => _BarState();
}

class _BarState extends State<_Bar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) =>
          Container(width: 2, height: 4 + _controller.value * 12, color: Theme.of(context).colorScheme.primary),
    );
  }
}
