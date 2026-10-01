import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Shimmer générique pour les états de chargement asynchrones (listes, recherche).
class SkeletonLoader extends StatelessWidget {
  const SkeletonLoader({super.key, this.height = 72});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      highlightColor: Theme.of(context).colorScheme.surface,
      child: Container(
        height: height,
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
