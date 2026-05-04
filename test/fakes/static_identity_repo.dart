import 'dart:typed_data';

import 'package:sharer/data/security/long_term_signer.dart';
import 'package:sharer/domain/entities/device_identity.dart';
import 'package:sharer/domain/repositories/device_identity_repository.dart';

/// Tiny test double that returns a fixed identity backed by a real
/// Ed25519 keypair (so `sign(...)` produces signatures that the
/// production verifier accepts). Keypair is reproducible from a seed
/// for stable test fixtures.
///
/// Use [StaticIdentityRepo.create] (async) for the typical case; the
/// constructor is exposed for tests that already hold a signer.
class StaticIdentityRepo implements DeviceIdentityRepository {
  StaticIdentityRepo._({
    required this.id,
    required this.name,
    required this.publicKey,
    required LongTermSigner signer,
  }) : _signer = signer;

  /// Builds a repo with a deterministic Ed25519 keypair derived from
  /// [seed] (defaults to 1). When [id] is null, it's derived from the
  /// public key fingerprint as production code does.
  static Future<StaticIdentityRepo> create({
    int seed = 1,
    String name = 'Test',
    String? id,
  }) async {
    final seedBytes = Uint8List.fromList(List<int>.filled(32, seed));
    final signer = await LongTermSigner.fromSeed(seedBytes);
    return StaticIdentityRepo._(
      id: id ?? signer.deviceIdFingerprint,
      name: name,
      publicKey: signer.publicKey,
      signer: signer,
    );
  }

  String id;
  String name;
  Uint8List publicKey;
  final LongTermSigner _signer;

  @override
  Future<DeviceIdentity> get() async => DeviceIdentity(
        id: id,
        name: name,
        publicKey: publicKey,
      );

  @override
  Future<void> rename(String name) async {
    this.name = name;
  }

  @override
  Future<List<int>> sign(List<int> message) => _signer.sign(message);
}
