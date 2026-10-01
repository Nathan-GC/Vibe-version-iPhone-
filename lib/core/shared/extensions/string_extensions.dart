extension StringSlug on String {
  String get slug => toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
}
