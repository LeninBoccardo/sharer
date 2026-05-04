import 'dart:typed_data';

import 'package:sharer/domain/entities/device_identity.dart';

/// Minimal `DeviceIdentity` factory for tests that just need a sender
/// label and don't care that the deviceId hashes correctly from the
/// publicKey. Use [StaticIdentityRepo.create] instead when the test
/// actually exercises Ed25519 signing/verification — that helper backs
/// the identity with a real deterministic keypair.
DeviceIdentity stubIdentity({
  String id = 'test-device-id',
  String name = 'Test',
  int seed = 0,
}) {
  final pub =
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));
  return DeviceIdentity(id: id, name: name, publicKey: pub);
}
