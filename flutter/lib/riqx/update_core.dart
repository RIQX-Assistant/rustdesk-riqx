// RIQX: the part of the in-app update with no FFI in it, so that
// test/riqx_update_test.dart can run it (docs/12-app-update.md).
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// 1.5.1 from now on; 1.5.0-r6.5 is what the first builds were called.
final _kVersion = RegExp(r'^\d+\.\d+\.\d+(-r\d+(\.\d+)*)?$');

bool riqxIsVersion(String v) => _kVersion.hasMatch(v);

/// A public page of the console. A build with no API setting of its own falls
/// back on upstream's address, which has no such page: then the RIQX site.
String riqxPanelPageUrl(String api, String path) {
  final base = api.trim().replaceAll(RegExp(r'/+$'), '');
  final host = Uri.tryParse(base)?.host ?? '';
  if (host.isEmpty || host == 'rustdesk.com' || host.endsWith('.rustdesk.com')) {
    return 'https://riqx.one';
  }
  return '$base$path';
}

/// -1 / 0 / 1 by number, not by text: «1.5.10» > «1.5.2» > «1.5.0-r6.5».
/// «1.5.0-r6.10» > «1.5.0-r6.2» > «1.5.0-r6» still holds for the first builds.
int riqxCompareVersions(String a, String b) {
  List<int> parts(String v) =>
      RegExp(r'\d+').allMatches(v).map((m) => int.parse(m.group(0)!)).toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// One row of {api}/api/riqx/update.
class RiqxUpdateFile {
  final int id;
  final String version;
  final String platform;
  final String arch;
  final String ext;
  final int size;
  final String sha256;
  final String signature;

  const RiqxUpdateFile(this.id, this.version, this.platform, this.arch,
      this.ext, this.size, this.sha256, this.signature);

  /// Null for anything malformed: the console's rows can be typed by hand.
  static RiqxUpdateFile? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = j['id'], size = j['size'];
    final version = j['version'], sha = j['sha256'];
    if (id is! int || size is! int || version is! String || sha is! String) {
      return null;
    }
    if (!riqxIsVersion(version) || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      return null;
    }
    return RiqxUpdateFile(id, version, '${j['platform'] ?? ''}',
        '${j['arch'] ?? ''}', '${j['ext'] ?? ''}', size, sha,
        '${j['signature'] ?? ''}');
  }
}

/// The file of the newest version above [current] for this machine, or null.
/// [archs] in order of preference. A newer version that only exists for
/// another architecture is not an update for this one.
RiqxUpdateFile? riqxPickFile(List<RiqxUpdateFile> files,
    {required String current,
    required String platform,
    required List<String> archs,
    required String ext}) {
  RiqxUpdateFile? best;
  for (final arch in archs) {
    for (final f in files) {
      if (f.platform != platform || f.arch != arch || f.ext != ext) continue;
      if (riqxCompareVersions(f.version, current) <= 0) continue;
      if (best == null || riqxCompareVersions(f.version, best.version) > 0) {
        best = f;
      }
    }
  }
  return best;
}

class RiqxUpdateError implements Exception {
  final String fa;
  final String en;
  const RiqxUpdateError(this.fa, this.en);
  @override
  String toString() => en;
}

const kRiqxErrNoNetwork = RiqxUpdateError(
    'به سرور دانلود نرسیدیم؛ اینترنت را بررسی کنید و دوباره بزنید.',
    'Could not reach the download server. Check your connection and try again.');
const kRiqxErrSlow = RiqxUpdateError(
    'دانلود نسخهٔ تازه بیش از حد طول کشید؛ دوباره بزنید.',
    'The download took too long. Please try again.');
const kRiqxErrHash = RiqxUpdateError(
    'فایل دانلودشده با اثر انگشتش جور نیست و نصب نشد؛ دوباره بزنید.',
    'The downloaded file failed its checksum and was not installed. Please try again.');

Future<bool> riqxFileMatches(File file, String sha) async {
  try {
    if (!await file.exists()) return false;
    return '${await sha256.bind(file.openRead()).first}' == sha;
  } on IOException {
    return false;
  }
}

/// Fetches [url] into [target] and checks it against [want]. [progress] gets
/// 0..1 as the bytes arrive. Nothing is left at [target] unless it checks out.
Future<void> riqxDownload(http.Client client, Uri url, File target, String want,
    int size, void Function(double) progress) async {
  try {
    // No redirect: the link was built from our own API address, not wherever a
    // redirect would lead. And a deadline for the answer itself: a server that
    // accepts and never answers must not hold the bar on 0% for good.
    final reply = await client
        .send(http.Request('GET', url)..followRedirects = false)
        .timeout(const Duration(seconds: 30));
    if (reply.statusCode != 200) {
      throw RiqxUpdateError(
          'دانلود نسخهٔ تازه ممکن نشد (کد ${reply.statusCode}).',
          'The download failed (code ${reply.statusCode}).');
    }
    final sink = target.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var got = 0;
    try {
      await for (final chunk
          in reply.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        hasher.add(chunk);
        got += chunk.length;
        if (size > 0) progress((got / size).clamp(0.0, 1.0));
      }
    } finally {
      hasher.close();
      await sink.close();
    }
    if ('${digest.value}' != want) throw kRiqxErrHash;
  } catch (e) {
    try {
      if (await target.exists()) await target.delete();
    } on IOException catch (_) {}
    if (e is RiqxUpdateError) rethrow;
    if (e is TimeoutException) throw kRiqxErrSlow;
    // SocketException, a broken TLS handshake, a connection lost mid-file
    // (http.ClientException), a folder that cannot be written.
    throw kRiqxErrNoNetwork;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// The strip across the top of the window. The colours are the brand's and the
/// same in both themes: it has to stand out from either.
class RiqxUpdateBar extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? onClose;
  final double? progress;
  final bool busy;
  final bool isError;

  const RiqxUpdateBar(
      {Key? key,
      required this.text,
      this.action,
      this.onAction,
      this.onClose,
      this.progress,
      this.busy = false,
      this.isError = false})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isError ? const Color(0xFFB42318) : const Color(0xFF2563EB),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            if (busy)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
            else
              const Icon(Icons.system_update_alt_rounded,
                  size: 18, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
            if (action != null && onAction != null) ...[
              const SizedBox(width: 10),
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF1D4ED8),
                    minimumSize: const Size(64, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Text(action!,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ],
            if (onClose != null)
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 16, color: Colors.white),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                splashRadius: 16,
              ),
          ]),
        ),
        if (progress != null)
          LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: Colors.white,
              backgroundColor: const Color(0x44FFFFFF)),
      ]),
    );
  }
}
