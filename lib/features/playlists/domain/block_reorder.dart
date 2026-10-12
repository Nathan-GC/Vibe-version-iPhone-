/// Réorganisation intelligente par bloc (Lot 3.2) : extrait les éléments
/// d'index [selected] (même non adjacents) et les réinsère en un bloc
/// contigu, dans leur ordre relatif d'origine, le premier occupant l'index
/// [target] de la liste finale — borné à la fin de la liste. Ex. positions
/// 2, 5 et 8 déplacées en position 10 : elles occupent 10, 11 et 12.
List<T> moveAsBlock<T>(List<T> items, Set<int> selected, int target) {
  final List<T> block = [
    for (int i = 0; i < items.length; i++)
      if (selected.contains(i)) items[i]
  ];
  final List<T> rest = [
    for (int i = 0; i < items.length; i++)
      if (!selected.contains(i)) items[i]
  ];
  return rest..insertAll(target.clamp(0, rest.length), block);
}
