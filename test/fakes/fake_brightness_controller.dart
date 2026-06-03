import 'package:sharer/data/system/brightness_controller.dart';

/// Records boost/restore calls so the pairing-screen lifecycle wiring can be
/// asserted without a real display.
class FakeBrightnessController implements BrightnessController {
  final List<String> calls = [];
  int get boostCount => calls.where((c) => c == 'boost').length;
  int get restoreCount => calls.where((c) => c == 'restore').length;

  @override
  Future<void> boostToMax() async => calls.add('boost');

  @override
  Future<void> restore() async => calls.add('restore');
}
