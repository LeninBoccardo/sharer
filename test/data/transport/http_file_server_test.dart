import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/hmac_signer.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/transfer_cipher.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/data/transport/incoming_event.dart';
import 'package:sharer/data/transport/transport_protocol.dart';
import 'package:sharer/domain/entities/paired_device.dart';

import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

({HttpFileServer server, StreamController<bool> trust, Directory dir}) _setup({
  HmacVerifier? verifier,
}) {
  final dir = Directory.systemTemp.createTempSync('sharer_server_test_');
  final trust = StreamController<bool>.broadcast();
  final server = HttpFileServer(
    downloads: FakeDownloadsLocator(dir),
    isTrusted: trust.stream,
    verifier: verifier,
    port: 0, // ephemeral
  );
  return (server: server, trust: trust, dir: dir);
}

/// Bundles a server with a wired verifier and one paired peer that the
/// test signs every request as. Mirrors slice 4.4's production posture
/// (verifier always set; only signed requests are accepted).
typedef _SignedFixture = ({
  HttpFileServer server,
  StreamController<bool> trust,
  Directory dir,
  PairedDevicesStore paired,
  HmacSigner signer,
  PairedDevice peer,
});

Future<_SignedFixture> _setupSigned({
  int seed = 7,
  int? maxTransferBytes,
  int? uploadOverSizeSlack,
}) async {
  final dir = Directory.systemTemp.createTempSync('sharer_server_test_');
  final trust = StreamController<bool>.broadcast();
  final paired = PairedDevicesStore(FakeSecureKeyValueStore());
  final peer = PairedDevice(
    deviceId: 'sender-1',
    displayName: 'Sender',
    psk: _psk(seed),
    publicKey: _stubPub(seed),
    pairedAt: DateTime.utc(2026, 5, 4),
  );
  await paired.add(peer);
  final server = HttpFileServer(
    downloads: FakeDownloadsLocator(dir),
    isTrusted: trust.stream,
    verifier: HmacVerifier(paired),
    port: 0,
    maxTransferBytes:
        maxTransferBytes ?? HttpFileServer.defaultMaxTransferBytes,
    uploadOverSizeSlack:
        uploadOverSizeSlack ?? HttpFileServer.defaultUploadOverSizeSlack,
  );
  return (
    server: server,
    trust: trust,
    dir: dir,
    paired: paired,
    signer: HmacSigner(),
    peer: peer,
  );
}

/// Sign + (optionally) encrypt + post a paired upload through a raw
/// [HttpClient]. Production goes through [HttpFileClient]; this helper
/// exists so server-side tests can exercise the wire shape directly.
///
/// - [signWithPsk] is the PSK used for the HMAC signature header.
/// - [encryptWithPsk] is the PSK used to derive the transferKey. When
///   null the body goes plaintext on the wire — useful for rejection
///   tests where the server is expected to 401 before reading the body.
/// - The transferId is always included (per slice 5.3 the server
///   requires it on signed requests; plaintext-but-signed bodies that
///   the rejection tests use never reach the decrypt step).
Future<HttpClientResponse> _postSignedUpload({
  required int port,
  required HmacSigner signer,
  required Uint8List signWithPsk,
  required Uint8List? encryptWithPsk,
  required String senderId,
  required String senderName,
  required String fileName,
  required List<int> body,
  int? declaredSize,
}) async {
  // The declared plaintext size (X-Sharer-FileSize + signed filesize) can
  // be overridden independently of the actual body so tests can exercise
  // the over-size (audit #10) and length-mismatch (audit #13) guards.
  final declared = declaredSize ?? body.length;
  final transferId = newTransferId(Random(31));
  final transferIdB64 = base64Encode(transferId);

  List<int> wireBody;
  if (encryptWithPsk != null) {
    final cipher = await TransferCipher.derive(
      psk: encryptWithPsk,
      transferId: transferId,
    );
    final acc = <int>[];
    await for (final part in cipher.encrypt(Stream.value(body))) {
      acc.addAll(part);
    }
    wireBody = acc;
  } else {
    wireBody = body;
  }

  final signed = signer.sign(
    psk: signWithPsk,
    method: 'POST',
    path: TransportProtocol.uploadPath,
    senderDeviceId: senderId,
    filename: fileName,
    filesize: declared,
    transferId: transferIdB64,
  );
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port${TransportProtocol.uploadPath}'),
    );
    req.headers.contentLength = wireBody.length;
    req.headers.set(
      TransportProtocol.headerFileName,
      Uri.encodeComponent(fileName),
    );
    req.headers.set(TransportProtocol.headerFileSize, declared.toString());
    req.headers.set(TransportProtocol.headerDeviceId, senderId);
    req.headers.set(
      TransportProtocol.headerDeviceName,
      Uri.encodeComponent(senderName),
    );
    req.headers.set(TransportProtocol.headerTransferId, transferIdB64);
    req.headers.set(TransportProtocol.headerTimestamp, signed.timestamp);
    req.headers.set(TransportProtocol.headerNonce, signed.nonce);
    req.headers.set(TransportProtocol.headerSignature, signed.signature);
    req.add(wireBody);
    return await req.close();
  } finally {
    client.close();
  }
}

/// Sends a plaintext, no-signature-headers POST. Used by the test that
/// confirms the server rejects unsigned uploads (slice 4.4 policy).
Future<HttpClientResponse> _postPlainUnsignedUpload({
  required int port,
  required String fileName,
  required List<int> body,
  String senderId = 'sender-1',
  String senderName = 'Sender',
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port${TransportProtocol.uploadPath}'),
    );
    req.headers.contentLength = body.length;
    req.headers.set(
      TransportProtocol.headerFileName,
      Uri.encodeComponent(fileName),
    );
    req.headers.set(TransportProtocol.headerFileSize, body.length.toString());
    req.headers.set(TransportProtocol.headerDeviceId, senderId);
    req.headers.set(
      TransportProtocol.headerDeviceName,
      Uri.encodeComponent(senderName),
    );
    req.add(body);
    return await req.close();
  } finally {
    client.close();
  }
}

Uint8List _psk(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

/// Stand-in 32-byte publicKey for tests that don't exercise Ed25519 —
/// the upload path verifies HMAC against the PSK, not the public key,
/// so this can be deterministic stub bytes.
Uint8List _stubPub(int seed) => Uint8List.fromList(
    List<int>.generate(32, (i) => (200 + seed + i) & 0xff));

void main() {
  group('HttpFileServer — always-on (slice 5.1)', () {
    test('binds on start regardless of trust state', () async {
      // Slice 5.1 changed the server to bind once on start() and stay
      // bound across trust transitions. Trust only gates the pair
      // routes, not the socket. See architecture.md "Transport —
      // strong rules" #1.
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(false);
      await _settle();

      expect(s.server.isRunning, isTrue,
          reason: 'server stays bound on untrusted networks');
      expect(s.server.boundPort, isNotNull);
    });

    test('stays bound through trust transitions', () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      await _settle();
      final boundPort = s.server.boundPort;
      expect(boundPort, isNotNull);

      s.trust.add(false);
      await _settle();
      expect(s.server.isRunning, isTrue,
          reason: 'untrust must not unbind the socket');
      expect(s.server.boundPort, boundPort,
          reason: 'port stays the same — paired peers cached this IP+port');

      s.trust.add(true);
      await _settle();
      expect(s.server.isRunning, isTrue);
    });

    test('stop() unbinds the socket', () async {
      final s = _setup();
      addTearDown(() async {
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      await _settle();
      expect(s.server.isRunning, isTrue);

      await s.server.stop();
      expect(s.server.isRunning, isFalse);
    });
  });

  group('HttpFileServer — upload (signed)', () {
    test('writes the body to disk and emits started + completed events',
        () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      final events = <IncomingEvent>[];
      final eventsSub = f.server.events.listen(events.add);

      await f.server.start();
      f.trust.add(true);
      await _settle();

      const payload = 'hello sharer world';
      final body = utf8.encode(payload);
      final response = await _postSignedUpload(
        port: f.server.boundPort!,
        signer: f.signer,
        signWithPsk: f.peer.psk,
        encryptWithPsk: f.peer.psk,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        fileName: 'greeting.txt',
        body: body,
      );

      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      final saved = File('${f.dir.path}${Platform.pathSeparator}greeting.txt');
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsString(), payload);

      expect(events.first, isA<IncomingStarted>());
      final started = events.first as IncomingStarted;
      expect(started.fileName, 'greeting.txt');
      expect(started.totalBytes, payload.length);
      expect(started.senderName, f.peer.displayName);

      expect(events.last, isA<IncomingCompleted>());
      expect((events.last as IncomingCompleted).savedPath,
          endsWith('greeting.txt'));

      await eventsSub.cancel();
    });

    test('rejects signed requests with no filename header (400)', () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      // 400 for missing filename, not 401 — verifier should never see this
      // request because the filename check happens first.
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse(
            'http://127.0.0.1:${f.server.boundPort}${TransportProtocol.uploadPath}'));
        req.headers.contentLength = 0;
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.badRequest);
        await resp.drain<void>();
      } finally {
        client.close();
      }
    });

    test('renames on collision (foo.txt → foo (1).txt)', () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      final port = f.server.boundPort!;
      final firstBody = utf8.encode('first');
      final secondBody = utf8.encode('second');
      await (await _postSignedUpload(
        port: port,
        signer: f.signer,
        signWithPsk: f.peer.psk,
        encryptWithPsk: f.peer.psk,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        fileName: 'foo.txt',
        body: firstBody,
      ))
          .drain<void>();
      await (await _postSignedUpload(
        port: port,
        signer: f.signer,
        signWithPsk: f.peer.psk,
        encryptWithPsk: f.peer.psk,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        fileName: 'foo.txt',
        body: secondBody,
      ))
          .drain<void>();
      await _settle();

      final first = File('${f.dir.path}${Platform.pathSeparator}foo.txt');
      final second =
          File('${f.dir.path}${Platform.pathSeparator}foo (1).txt');
      expect(await first.readAsString(), 'first');
      expect(await second.readAsString(), 'second');
    });

    test('concurrent uploads of the same filename do not clobber '
        '(TOCTOU, audit #11)', () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      final port = f.server.boundPort!;
      // Large bodies (> _progressThresholdBytes) widen the race window.
      final body1 = utf8.encode('A' * (400 * 1024));
      final body2 = utf8.encode('B' * (400 * 1024));

      // Fire both WITHOUT awaiting the first, so they interleave on the
      // server and exercise the create-exclusive reservation race.
      final responses = await Future.wait([
        _postSignedUpload(
          port: port,
          signer: f.signer,
          signWithPsk: f.peer.psk,
          encryptWithPsk: f.peer.psk,
          senderId: f.peer.deviceId,
          senderName: f.peer.displayName,
          fileName: 'clash.txt',
          body: body1,
        ),
        _postSignedUpload(
          port: port,
          signer: f.signer,
          signWithPsk: f.peer.psk,
          encryptWithPsk: f.peer.psk,
          senderId: f.peer.deviceId,
          senderName: f.peer.displayName,
          fileName: 'clash.txt',
          body: body2,
        ),
      ]);
      for (final r in responses) {
        expect(r.statusCode, HttpStatus.ok);
        await r.drain<void>();
      }
      await _settle();

      final files = f.dir.listSync().whereType<File>().toList();
      expect(files, hasLength(2),
          reason: 'two same-name uploads must yield two distinct files');
      expect(files.map((e) => e.uri.pathSegments.last).toSet(),
          {'clash.txt', 'clash (1).txt'});
      final contents = files.map((e) => e.readAsStringSync()).toList()..sort();
      final expected = [utf8.decode(body1), utf8.decode(body2)]..sort();
      expect(contents, expected,
          reason: 'neither body was clobbered or truncated');
    });

    test('sanitizes path-traversal attempts in the filename header',
        () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      final body = utf8.encode('nope');
      final response = await _postSignedUpload(
        port: f.server.boundPort!,
        signer: f.signer,
        signWithPsk: f.peer.psk,
        encryptWithPsk: f.peer.psk,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        fileName: '../../etc/passwd',
        body: body,
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      final escaped = Directory(
          '${f.dir.parent.parent.path}${Platform.pathSeparator}etc');
      expect(escaped.existsSync(), isFalse,
          reason: 'should not have written outside the downloads dir');
      expect(f.dir.listSync(), isNotEmpty);
    });

    test('rejects a signed upload whose received length != signed '
        'totalBytes (truncation, audit #13)', () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      final events = <IncomingEvent>[];
      final eventsSub = f.server.events.listen(events.add);

      await f.server.start();
      f.trust.add(true);
      await _settle();

      // Sign/declare 1000 plaintext bytes but ship only 64 valid encrypted
      // bytes — every delivered GCM frame verifies, so only the signed
      // length check catches the truncation.
      final body = utf8.encode('A' * 64);
      final resp = await _postSignedUpload(
        port: f.server.boundPort!,
        signer: f.signer,
        signWithPsk: f.peer.psk,
        encryptWithPsk: f.peer.psk,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        fileName: 'short.bin',
        body: body,
        declaredSize: 1000,
      );
      expect(resp.statusCode, HttpStatus.internalServerError);
      await resp.drain<void>();
      await _settle();

      expect(f.dir.listSync().whereType<File>(), isEmpty,
          reason: 'truncated transfer leaves no partial file');
      expect(events.last, isA<IncomingFailed>(),
          reason: 'truncated transfer ends in failure, not completion');

      await eventsSub.cancel();
    });

    test('aborts an /upload that grossly overruns its declared size with '
        '413 (audit #10)', () async {
      final f = await _setupSigned(uploadOverSizeSlack: 0);
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      final events = <IncomingEvent>[];
      final eventsSub = f.server.events.listen(events.add);

      await f.server.start();
      f.trust.add(true);
      await _settle();

      // Declare 8 bytes (signed) but actually ship 64 — with zero slack
      // the in-loop guard trips and aborts before the post-loop backstop.
      final body = utf8.encode('A' * 64);
      int? status;
      try {
        final resp = await _postSignedUpload(
          port: f.server.boundPort!,
          signer: f.signer,
          signWithPsk: f.peer.psk,
          encryptWithPsk: f.peer.psk,
          senderId: f.peer.deviceId,
          senderName: f.peer.displayName,
          fileName: 'liar.bin',
          body: body,
          declaredSize: 8,
        );
        status = resp.statusCode;
        await resp.drain<void>();
      } on SocketException {
        // mid-stream abort may reset the connection — also a refusal
      } on HttpException {
        // likewise
      }
      await _settle();

      if (status != null) {
        expect(status, HttpStatus.requestEntityTooLarge,
            reason: 'gross over-size abort returns 413');
        // Over-size is not an unpair trigger — no reason header.
      }
      expect(f.dir.listSync().whereType<File>(), isEmpty,
          reason: 'partial deleted on over-size abort');
      expect(events.whereType<IncomingFailed>(), isNotEmpty);

      await eventsSub.cancel();
    });

    test('aborts an /upload exceeding the per-transfer ceiling with 507 '
        '(audit #25)', () async {
      final f = await _setupSigned(maxTransferBytes: 8);
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      final events = <IncomingEvent>[];
      final eventsSub = f.server.events.listen(events.add);

      await f.server.start();
      f.trust.add(true);
      await _settle();

      // 64 plaintext bytes, far over the 8-byte ceiling.
      final body = utf8.encode('A' * 64);
      int? status;
      try {
        final resp = await _postSignedUpload(
          port: f.server.boundPort!,
          signer: f.signer,
          signWithPsk: f.peer.psk,
          encryptWithPsk: f.peer.psk,
          senderId: f.peer.deviceId,
          senderName: f.peer.displayName,
          fileName: 'big.bin',
          body: body,
        );
        status = resp.statusCode;
        if (status == 507) {
          expect(resp.headers.value(TransportProtocol.headerReason),
              TransportProtocol.reasonStorageFull);
        }
        await resp.drain<void>();
      } on SocketException {
        // A mid-stream abort can reset the connection — also a refusal.
      } on HttpException {
        // likewise
      }
      await _settle();

      if (status != null) {
        expect(status, 507, reason: 'capacity abort returns 507');
      }
      expect(f.dir.listSync().whereType<File>(), isEmpty,
          reason: 'partial file deleted on capacity abort');
      expect(events.whereType<IncomingFailed>(), isNotEmpty,
          reason: 'capacity abort emits IncomingFailed');

      await eventsSub.cancel();
    });

    test('sanitizes Windows-illegal chars + reserved device names (audit #24)',
        () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      Future<void> send(String fileName) async {
        await (await _postSignedUpload(
          port: f.server.boundPort!,
          signer: f.signer,
          signWithPsk: f.peer.psk,
          encryptWithPsk: f.peer.psk,
          senderId: f.peer.deviceId,
          senderName: f.peer.displayName,
          fileName: fileName,
          body: utf8.encode('x'),
        ))
            .drain<void>();
        await _settle();
      }

      await send('report.pdf:evil.exe'); // NTFS ADS / drive-relative vector
      await send('a<b>c"d|e?f*g.txt'); // other Win32-illegal chars
      await send('CON'); // reserved DOS device name

      final names =
          f.dir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, contains('report.pdf_evil.exe'),
          reason: 'colon replaced — no ADS stream reachable');
      expect(names, contains('a_b_c_d_e_f_g.txt'));
      expect(names, contains('_CON'),
          reason: 'reserved device name prefixed with _');
      expect(names.any((n) => n.contains(':')), isFalse,
          reason: 'no colon (ADS) filename should survive sanitization');
    });
  });

  group('HttpFileServer — HMAC verification', () {
    late FakeSecureKeyValueStore secure;
    late PairedDevicesStore paired;
    late HmacSigner signer;
    late HmacVerifier verifier;

    setUp(() {
      secure = FakeSecureKeyValueStore();
      paired = PairedDevicesStore(secure);
      signer = HmacSigner();
      verifier = HmacVerifier(paired);
    });

    tearDown(() => paired.dispose());

    test('accepts a valid signed request from a paired peer', () async {
      final peer = PairedDevice(
        deviceId: 'realme',
        displayName: 'Realme',
        psk: _psk(7),
        publicKey: _stubPub(7),
        pairedAt: DateTime.utc(2026, 5, 4),
      );
      await paired.add(peer);

      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final body = utf8.encode('signed-hello');
      final response = await _postSignedUpload(
        port: s.server.boundPort!,
        signer: signer,
        signWithPsk: peer.psk,
        encryptWithPsk: peer.psk,
        senderId: peer.deviceId,
        senderName: peer.displayName,
        fileName: 'note.txt',
        body: body,
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
    });

    test('rejects with 403 + unknown-sender when signed by a non-paired '
        'sender', () async {
      // Verifier knows nobody — request is rejected at the HMAC gate
      // before the body is read. Audit #1: an unknown sender is the one
      // rejection that means "you forgot me", so it returns a distinct
      // 403 + X-Sharer-Reason so the sender can reactively forget.
      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final body = utf8.encode('attempt');
      final response = await _postSignedUpload(
        port: s.server.boundPort!,
        signer: signer,
        signWithPsk: _psk(99),
        encryptWithPsk: null,
        senderId: 'stranger',
        senderName: 'Stranger',
        fileName: 'note.txt',
        body: body,
      );
      expect(response.statusCode, HttpStatus.forbidden);
      expect(response.headers.value(TransportProtocol.headerReason),
          TransportProtocol.reasonUnknownSender);
      await response.drain<void>();
    });

    test('rejects when signed with the wrong PSK', () async {
      final peer = PairedDevice(
        deviceId: 'realme',
        displayName: 'Realme',
        psk: _psk(7),
        publicKey: _stubPub(7),
        pairedAt: DateTime.utc(2026, 5, 4),
      );
      await paired.add(peer);

      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final body = utf8.encode('attempt');
      final response = await _postSignedUpload(
        port: s.server.boundPort!,
        signer: signer,
        signWithPsk: _psk(99), // wrong PSK — HMAC check rejects
        encryptWithPsk: null,
        senderId: peer.deviceId,
        senderName: peer.displayName,
        fileName: 'note.txt',
        body: body,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();
    });

    test('rejects unsigned uploads with 401 even on trusted network '
        '(slice 4.4)', () async {
      // Pairing is the only path to /upload. Trusted-network is no longer
      // an authorization fallback. See docs/v1/security.md §5.
      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final response = await _postPlainUnsignedUpload(
        port: s.server.boundPort!,
        fileName: 'unsigned.txt',
        body: utf8.encode('should be rejected'),
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();

      // And nothing landed on disk.
      expect(s.dir.listSync(), isEmpty);
    });

    test('rejects partial signature headers (presence implies completeness)',
        () async {
      final peer = PairedDevice(
        deviceId: 'realme',
        displayName: 'Realme',
        psk: _psk(7),
        publicKey: _stubPub(7),
        pairedAt: DateTime.utc(2026, 5, 4),
      );
      await paired.add(peer);

      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      // Send only timestamp, not the rest.
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse(
            'http://127.0.0.1:${s.server.boundPort}${TransportProtocol.uploadPath}'));
        req.headers.contentLength = 4;
        req.headers.set(
            TransportProtocol.headerFileName, Uri.encodeComponent('a.txt'));
        req.headers.set(TransportProtocol.headerFileSize, '4');
        req.headers.set(TransportProtocol.headerDeviceId, peer.deviceId);
        req.headers.set(TransportProtocol.headerTimestamp,
            DateTime.now().millisecondsSinceEpoch.toString());
        req.add(utf8.encode('test'));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.unauthorized);
        await resp.drain<void>();
      } finally {
        client.close();
      }
    });
  });
}
