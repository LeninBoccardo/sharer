import '../entities/network_info.dart';

abstract class NetworkWatcherRepository {
  /// Emits the current network whenever it changes (connect, SSID change,
  /// subnet change, disconnect → null).
  Stream<NetworkInfo?> watch();

  /// Snapshot of the current network. Useful for one-shot reads (e.g. when
  /// promoting the current network to trusted).
  Future<NetworkInfo?> current();

  /// Adds [info]'s fingerprint to the persistent trusted-network list.
  Future<void> trust(NetworkInfo info);

  /// Removes [info]'s fingerprint from the trusted list.
  Future<void> untrust(NetworkInfo info);

  /// Reactive view of "is the current network in the trusted set?"
  Stream<bool> watchIsTrusted();
}
