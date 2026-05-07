// Slice 5.x.5 phase 3 — static validation of Linux native scaffold.
//
// We can't run Linux locally; these tests parse the config files
// and assert load-bearing keys are present + correct. Catches:
//   - .desktop file with wrong Type, missing Exec, etc. (file managers
//     refuse to launch the entry, AppImage tools refuse to package)
//   - my_application.cc accidentally regaining G_APPLICATION_NON_UNIQUE
//     (would silently break the slice 5.x.3.4-equivalent single-instance
//     behavior; second-launch would start a parallel HTTP server racing
//     for port 8080)
//
// These tests run on every platform; they only read files.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strip `// ...` line comments and `/* ... */` block comments from C/C++
/// source so a literal-string match doesn't trip on the explanatory
/// comment that mentions the symbol we're checking is absent.
String _stripCppComments(String source) {
  // Block comments (non-greedy, `s` flag = dot matches newlines).
  var s = source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  // Line comments — careful NOT to match `//` inside string literals.
  // Our test target has no relevant strings containing `//`, so a
  // simple per-line match is sufficient.
  s = s.split('\n').map((line) {
    final i = line.indexOf('//');
    return i >= 0 ? line.substring(0, i) : line;
  }).join('\n');
  return s;
}

/// Minimal .desktop file parser. Format spec:
/// https://specifications.freedesktop.org/desktop-entry-spec/latest/
/// One [Group] line, then `key=value` lines, comments start with `#`.
Map<String, String> _parseDesktop(File file) {
  final lines = file.readAsLinesSync();
  final group = <String, String>{};
  var inDesktopEntry = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      inDesktopEntry = (line == '[Desktop Entry]');
      continue;
    }
    if (!inDesktopEntry) continue;
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    group[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return group;
}

void main() {
  group('linux/sharer.desktop (slice 5.x.5 phase 3)', () {
    late Map<String, String> entry;
    setUpAll(() {
      final file = File('linux/sharer.desktop');
      expect(file.existsSync(), isTrue,
          reason: 'linux/sharer.desktop is required for AppImage '
              'packaging + native file-manager integration');
      entry = _parseDesktop(file);
    });

    test('declares Type=Application', () {
      expect(entry['Type'], 'Application',
          reason: 'GNOME / KDE / appimagetool all reject .desktop files '
              'whose Type is missing or != Application');
    });

    test('Name= is non-empty', () {
      expect(entry['Name'], isNotNull);
      expect(entry['Name']!.trim(), isNotEmpty);
    });

    test('Exec= references the binary name (no absolute path)', () {
      final exec = entry['Exec'];
      expect(exec, isNotNull);
      expect(exec!.trim(), isNotEmpty);
      // AppImage rewrites Exec= at runtime. Static .desktop files
      // shipped with debs / flatpaks / direct installs use the binary
      // name only, relying on PATH or the icon-search-path.
      expect(exec.startsWith('/'), isFalse,
          reason: 'Exec= should be a binary name resolved via PATH, not '
              'an absolute path. AppImage runtime rewrites this; '
              'absolute paths break installs that put the binary in a '
              'different prefix');
    });

    test('Icon= is set so launchers / AppImage can render', () {
      expect(entry['Icon'], isNotNull);
      expect(entry['Icon']!.trim(), isNotEmpty);
    });

    test('Categories= includes both Network and FileTransfer', () {
      final cats = entry['Categories'] ?? '';
      // Categories spec: separated by `;`, must be from the FreeDesktop
      // standard list. Network + FileTransfer is the canonical pair
      // for an LAN file-share app — it makes sharer appear in both
      // "Internet" and "Utilities" submenus on most desktop envs.
      final parts = cats.split(';').where((s) => s.isNotEmpty).toSet();
      expect(parts, contains('Network'));
      expect(parts, contains('FileTransfer'));
    });

    test('Terminal=false (we are a GUI app)', () {
      expect(entry['Terminal'], 'false');
    });

    test('StartupWMClass matches the binary name', () {
      // StartupWMClass tells the window manager which X11 / Wayland
      // window class corresponds to this .desktop entry. If wrong, the
      // taskbar shows two icons (one for the .desktop, one for the
      // running window). Matching the binary name is the
      // flutter-build-linux default.
      expect(entry['StartupWMClass'], 'sharer');
    });
  });

  group('linux/runner/my_application.cc (slice 5.x.5 phase 3)', () {
    late String source;
    late String sourceNoComments;
    setUpAll(() {
      source = File('linux/runner/my_application.cc').readAsStringSync();
      sourceNoComments = _stripCppComments(source);
    });

    test('does NOT use G_APPLICATION_NON_UNIQUE outside comments '
        '(single-instance enabled)', () {
      // This is the most important Linux invariant: the flutter-create
      // default opted out of GApplication's D-Bus uniqueness. Slice
      // 5.x.5 phase 3 turns it back on so a second launch forwards to
      // the primary instead of starting a parallel HTTP server racing
      // for port 8080. Equivalent to the Windows mutex from slice
      // 5.x.3.4.
      //
      // Comments mentioning the symbol historically (in our edit's
      // explanation) don't count — we strip C/C++ comments before
      // matching.
      expect(sourceNoComments, isNot(contains('G_APPLICATION_NON_UNIQUE')),
          reason: 'A future flutter-create regenerate or merge could '
              'reintroduce G_APPLICATION_NON_UNIQUE. This test fails '
              "when that happens so we don't ship a release with two "
              'sharer processes racing on every double-launch.');
      // And positively assert the replacement is in place.
      expect(sourceNoComments, contains('G_APPLICATION_FLAGS_NONE'),
          reason: 'Single-instance behavior depends on '
              'G_APPLICATION_FLAGS_NONE (or any non-NON_UNIQUE flag).');
    });

    test('tracks the existing window in main_window for re-activation',
        () {
      // Without this guard, a second-process activation would land in
      // my_application_activate, create another GtkWindow, and the
      // primary instance would now have two windows pointing at the
      // same Flutter engine.
      expect(source, contains('main_window'),
          reason: 'main_window field is the dedup latch for second-'
              'launch activations; if this name disappears, the single-'
              'instance behavior probably regressed.');
      expect(source, contains('gtk_window_present'),
          reason: 'Re-activation must call gtk_window_present (or '
              'equivalent) to bump the existing window forward; '
              "otherwise the user sees nothing happen and assumes the "
              'second launch silently failed.');
    });
  });

  group('linux/packaging scripts (slice 5.x.5 phase 3)', () {
    test('AppRun launcher exists and references the bundled exec', () {
      final apprun = File('linux/packaging/AppRun');
      expect(apprun.existsSync(), isTrue);
      final body = apprun.readAsStringSync();
      expect(body, contains('LD_LIBRARY_PATH'),
          reason: 'AppRun MUST set LD_LIBRARY_PATH so the bundled '
              'libsecret takes precedence over the host. Otherwise '
              'distros without libsecret installed crash on first '
              'flutter_secure_storage call.');
      expect(body, contains('exec'),
          reason: 'AppRun should exec the real binary so signal '
              "delivery + parent-process semantics aren't broken by an "
              'extra shell layer.');
    });

    test('build-appimage.sh exists and produces the expected artifact name',
        () {
      final script = File('linux/packaging/build-appimage.sh');
      expect(script.existsSync(), isTrue);
      final body = script.readAsStringSync();
      expect(body, contains('Sharer-x86_64.AppImage'),
          reason: 'CI workflow build-matrix.yml uploads this exact '
              'filename pattern; if the script renames it, the upload '
              'silently produces an empty artifact.');
      expect(body, contains('libsecret-1'),
          reason: 'The script bundles libsecret-1 into the AppImage. '
              'If that bundling step is removed, hosts without '
              'libsecret installed fail to launch.');
    });
  });
}
