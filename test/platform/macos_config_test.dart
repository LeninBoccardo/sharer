// Slice 5.x.5 phase 2 — static validation of macOS native scaffold.
//
// We can't run macOS locally; these tests parse the config files as XML
// and assert the load-bearing keys are present + correct. Catches:
//   - Typos in NSBonjourServices entries (silent mDNS denial otherwise)
//   - Missing NSLocalNetworkUsageDescription (no permission prompt → no
//     network access on macOS 13+ and the failure mode is invisible)
//   - Release entitlements missing network entitlements that Debug had
//     (release builds work in dev but break for end users)
//
// These tests run on every platform; they only read files, don't touch
// the OS.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// Returns the workspace root by walking up from the test file location.
/// `flutter test` runs from the package root, so File('macos/...') is
/// already correct — this helper is just defensive in case something
/// changes the cwd later.
File _projectFile(String relative) {
  final candidate = File(relative);
  if (candidate.existsSync()) return candidate;
  // Fallback: navigate from Platform.script if direct relative fails.
  final scriptDir = File.fromUri(Platform.script).parent;
  return File('${scriptDir.path}/$relative');
}

/// Walk a parsed plist `<dict>` looking for a sibling pair
/// (`<key>NAME</key>`, `<value-element/>`). Returns the value element
/// or null. Plist `<dict>`s are key/value pairs encoded as ordered
/// `<key>` + value siblings, so proper plist parsers iterate children
/// in pairs rather than treating it as a Map.
XmlElement? _plistValueFor(XmlElement dictElement, String key) {
  final children = dictElement.children
      .whereType<XmlElement>()
      .toList(growable: false);
  for (var i = 0; i < children.length - 1; i++) {
    if (children[i].name.local == 'key' && children[i].innerText == key) {
      return children[i + 1];
    }
  }
  return null;
}

XmlElement _rootDict(File file) {
  expect(file.existsSync(), isTrue,
      reason: '${file.path} must exist for the macOS build to succeed');
  final doc = XmlDocument.parse(file.readAsStringSync());
  final plist = doc.rootElement;
  expect(plist.name.local, 'plist',
      reason: 'root element of ${file.path} must be <plist>');
  final dict = plist.children
      .whereType<XmlElement>()
      .firstWhere((e) => e.name.local == 'dict',
          orElse: () => throw StateError(
              '${file.path} has no <dict> inside <plist>'));
  return dict;
}

void main() {
  group('macOS Info.plist (slice 5.x.5 phase 2)', () {
    late XmlElement dict;
    setUpAll(() {
      dict = _rootDict(_projectFile('macos/Runner/Info.plist'));
    });

    test('declares NSBonjourServices including _sharer._tcp', () {
      final value = _plistValueFor(dict, 'NSBonjourServices');
      expect(value, isNotNull,
          reason: 'NSBonjourServices is REQUIRED on macOS 13+ for '
              'NSNetServiceBrowser to return results. Without it, Bonsoir '
              "silently finds zero peers and the user can't tell why.");
      expect(value!.name.local, 'array',
          reason: 'NSBonjourServices must be an <array> of <string>s');
      final services = value.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'string')
          .map((e) => e.innerText)
          .toList();
      expect(services, contains('_sharer._tcp'),
          reason: 'Must declare _sharer._tcp (no trailing dot, no .local). '
              "Apple's docs are clear: trailing-dot variants are NOT "
              'recognised here.');
    });

    test('declares NSLocalNetworkUsageDescription with non-empty copy', () {
      final value = _plistValueFor(dict, 'NSLocalNetworkUsageDescription');
      expect(value, isNotNull,
          reason: 'Without this key, macOS will not prompt the user for '
              'local-network permission and Bonsoir browse silently '
              'returns nothing. The string is shown in the permission '
              'dialog — Apple rejects empty strings.');
      expect(value!.name.local, 'string');
      expect(value.innerText.trim(), isNotEmpty);
      expect(value.innerText.length, greaterThan(20),
          reason: 'Apple HIG suggests a sentence explaining WHY the app '
              'needs the permission, not just "Network access".');
    });
  });

  group('macOS DebugProfile.entitlements (slice 5.x.5 phase 2)', () {
    late XmlElement dict;
    setUpAll(() {
      dict = _rootDict(
          _projectFile('macos/Runner/DebugProfile.entitlements'));
    });

    test('enables network.server', () {
      final value = _plistValueFor(dict, 'com.apple.security.network.server');
      expect(value, isNotNull);
      expect(value!.name.local, 'true');
    });

    test('enables network.client', () {
      final value = _plistValueFor(dict, 'com.apple.security.network.client');
      expect(value, isNotNull,
          reason: 'Sharer is both server AND client (uploads to peers). '
              'Sandbox blocks outbound TCP without this flag.');
      expect(value!.name.local, 'true');
    });

    test('declares app-sandbox=true (Apple-required for store/notarized)',
        () {
      final value = _plistValueFor(dict, 'com.apple.security.app-sandbox');
      expect(value, isNotNull);
      expect(value!.name.local, 'true');
    });
  });

  group('macOS Release.entitlements (slice 5.x.5 phase 2)', () {
    late XmlElement dict;
    setUpAll(() {
      dict = _rootDict(_projectFile('macos/Runner/Release.entitlements'));
    });

    test('enables network.server (parity with Debug)', () {
      final value = _plistValueFor(dict, 'com.apple.security.network.server');
      expect(value, isNotNull,
          reason: 'Most common macOS shipping bug: dev works because Debug '
              'entitlements include the network flag, but Release omits '
              'it and the shipped .app silently fails every bind. Both '
              'configurations MUST be in lockstep.');
      expect(value!.name.local, 'true');
    });

    test('enables network.client (parity with Debug)', () {
      final value = _plistValueFor(dict, 'com.apple.security.network.client');
      expect(value, isNotNull);
      expect(value!.name.local, 'true');
    });

    test('declares app-sandbox=true', () {
      final value = _plistValueFor(dict, 'com.apple.security.app-sandbox');
      expect(value, isNotNull);
      expect(value!.name.local, 'true');
    });
  });
}
