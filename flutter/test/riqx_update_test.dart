import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/riqx/update_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

RiqxUpdateFile file(String version, String platform, String arch, String ext,
        {int id = 1}) =>
    RiqxUpdateFile(id, version, platform, arch, ext, 1, 'a' * 64, '');

void main() {
  test('versions compare by number, not by text', () {
    expect(riqxCompareVersions('1.5.0-r6.2', '1.5.0-r6.3'), -1);
    expect(riqxCompareVersions('1.5.0-r6.10', '1.5.0-r6.2'), 1);
    expect(riqxCompareVersions('1.5.0-r6.1', '1.5.0-r6'), 1);
    expect(riqxCompareVersions('1.5.0-r6', '1.5.0-r6.0'), 0);
    expect(riqxCompareVersions('1.5.0-r10', '1.5.0-r9.9'), 1);
    expect(riqxCompareVersions('1.6.0-r1', '1.5.0-r9'), 1);
  });

  test('only a tagged build has a version of its own', () {
    expect(riqxIsVersion('1.5.0-r6.3'), isTrue);
    expect(riqxIsVersion('1.5.0-r7'), isTrue);
    expect(riqxIsVersion(''), isFalse);
    expect(riqxIsVersion('1.5.0'), isFalse);
    expect(riqxIsVersion('1.5.0-r6.3-mobile-mac'), isFalse);
    expect(riqxIsVersion('riqx-1.5.0'), isFalse);
  });

  test('a malformed row is dropped', () {
    final good = {
      'id': 4,
      'version': '1.5.0-r6.3',
      'platform': 'windows',
      'arch': 'x86_64',
      'ext': 'msi',
      'size': 10,
      'sha256': 'a' * 64,
      'signature': null,
    };
    expect(RiqxUpdateFile.fromJson(good)!.signature, '');
    expect(RiqxUpdateFile.fromJson({...good, 'version': 'test'}), isNull);
    expect(RiqxUpdateFile.fromJson({...good, 'sha256': 'abc'}), isNull);
    expect(RiqxUpdateFile.fromJson({...good, 'id': '4'}), isNull);
    expect(RiqxUpdateFile.fromJson('x'), isNull);
  });

  group('choosing the file', () {
    final files = [
      file('1.5.0-r6.3', 'windows', 'x86_64', 'msi', id: 1),
      file('1.5.0-r6.3', 'windows', 'x86_64', 'exe', id: 2),
      file('1.5.0-r6.3', 'android', 'arm64', 'apk', id: 3),
      file('1.5.0-r6.3', 'android', 'universal', 'apk', id: 4),
    ];
    RiqxUpdateFile? win(String current) => riqxPickFile(files,
        current: current, platform: 'windows', archs: ['x86_64'], ext: 'msi');

    test('newer: the MSI; same or newer installed: nothing', () {
      expect(win('1.5.0-r6.2')!.id, 1);
      expect(win('1.5.0-r6.3'), isNull);
      expect(win('1.5.0-r6.10'), isNull);
    });

    test('the phone\'s own ABI first, universal otherwise', () {
      RiqxUpdateFile? android(List<String> archs) => riqxPickFile(files,
          current: '1.5.0-r6.2', platform: 'android', archs: archs, ext: 'apk');
      expect(android(['arm64', 'universal'])!.id, 3);
      expect(android(['armv7', 'universal'])!.id, 4);
      expect(android([])?.id, isNull);
    });

    test('the newest version wins over the preferred architecture', () {
      final mixed = [
        file('1.5.0-r6.3', 'android', 'arm64', 'apk', id: 1),
        file('1.5.0-r6.4', 'android', 'universal', 'apk', id: 2),
      ];
      expect(
          riqxPickFile(mixed,
                  current: '1.5.0-r6.2',
                  platform: 'android',
                  archs: ['arm64', 'universal'],
                  ext: 'apk')!
              .id,
          2);
    });
  });

  group('download', () {
    late Directory dir;
    late File target;
    final bytes = utf8.encode('the new installer');
    final good = '${sha256.convert(bytes)}';
    final url = Uri.parse('https://x/downloads/1');

    setUp(() {
      dir = Directory.systemTemp.createTempSync('riqx_update_test');
      target = File('${dir.path}/RIQX 1.msi');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    http.Client serving(http.StreamedResponse Function() reply) =>
        MockClient.streaming((_, __) async => reply());

    test('a good file arrives, with progress up to 1', () async {
      final seen = <double>[];
      await riqxDownload(
          serving(() => http.StreamedResponse(Stream.value(bytes), 200)),
          url,
          target,
          good,
          bytes.length,
          seen.add);
      expect(target.readAsBytesSync(), bytes);
      expect(seen.last, 1.0);
      expect(await riqxFileMatches(target, good), isTrue);
      expect(await riqxFileMatches(target, 'b' * 64), isFalse);
    });

    test('a wrong file is refused and nothing stays behind', () async {
      await expectLater(
          riqxDownload(
              serving(() => http.StreamedResponse(Stream.value(bytes), 200)),
              url,
              target,
              'b' * 64,
              bytes.length,
              (_) {}),
          throwsA(same(kRiqxErrHash)));
      expect(target.existsSync(), isFalse);
    });

    test('a redirect is not followed', () async {
      late http.BaseRequest asked;
      final client = MockClient.streaming((request, _) async {
        asked = request;
        return http.StreamedResponse(const Stream.empty(), 302);
      });
      await expectLater(
          riqxDownload(client, url, target, good, 1, (_) {}),
          throwsA(isA<RiqxUpdateError>()
              .having((e) => e.en, 'en', contains('302'))));
      expect(asked.followRedirects, isFalse);
      expect(target.existsSync(), isFalse);
    });

    test('a connection lost mid-file frees the bar and leaves nothing',
        () async {
      Stream<List<int>> broken() async* {
        yield bytes;
        throw http.ClientException('connection closed');
      }

      await expectLater(
          riqxDownload(serving(() => http.StreamedResponse(broken(), 200)), url,
              target, good, 100, (_) {}),
          throwsA(same(kRiqxErrNoNetwork)));
      expect(target.existsSync(), isFalse);
    });
  });

  testWidgets('the strip fits a phone, in Persian, with the longest text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var pressed = false;
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: RiqxUpdateBar(
            text: 'در حال نصب… اگر ویندوز اجازه خواست، «Yes» را بزنید. '
                    'اپ بسته و دوباره باز می‌شود. ' *
                3,
            action: 'دانلود',
            onAction: () => pressed = true,
            onClose: () {},
            progress: .4,
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('دانلود'));
    expect(pressed, isTrue);
  });
}
