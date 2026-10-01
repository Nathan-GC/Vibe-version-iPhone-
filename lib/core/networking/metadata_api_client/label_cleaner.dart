/// Nettoie le champ `copyright` iTunes ("℗ 2001 Daft Life Limited" devient
/// "Daft Life Limited") pour n'afficher que le nom du label — le symbole de
/// copyright phonographique et l'année (déjà affichée séparément à côté) n'ont
/// pas leur place dans un badge de label.
class LabelCleaner {
  const LabelCleaner._();

  static final RegExp _prefix = RegExp(r'^[℗©]\s*\d{4}\s*');

  static String? clean(String? raw) {
    if (raw == null) return null;
    final String cleaned = raw.replaceFirst(_prefix, '').trim();
    return cleaned.isEmpty ? null : cleaned;
  }
}
