import 'package:sharer/domain/entities/device_identity.dart';
import 'package:sharer/domain/repositories/device_identity_repository.dart';

/// Tiny test double that returns a fixed identity. Useful anywhere a
/// service depends on DeviceIdentityRepository but the test doesn't
/// care about the rename path.
class StaticIdentityRepo implements DeviceIdentityRepository {
  StaticIdentityRepo({required this.id, required this.name});

  String id;
  String name;

  @override
  Future<DeviceIdentity> get() async => DeviceIdentity(id: id, name: name);

  @override
  Future<void> rename(String name) async {
    this.name = name;
  }
}
