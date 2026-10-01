/// Levée par [StorageManagerService.checkAvailableStorage] quand l'espace
/// libre sur l'appareil est inférieur à ce que l'opération demande.
class InsufficientStorageException implements Exception {
  const InsufficientStorageException({required this.requiredBytes, required this.availableBytes});

  final int requiredBytes;
  final int availableBytes;

  @override
  String toString() =>
      'InsufficientStorageException: $requiredBytes octets requis, $availableBytes octets disponibles.';
}
