// RIQX: ADS1 (bottom of the left column) and ADS2 (banner above the status bar;
// the bottom banner on Android), managed in the RIQX console (System -> Ads).
//
// The console serves a manifest at {api}/api/riqx/ads?lang=fa|en with an ETag;
// media live at immutable /media/{id}/{sha256}.{ext} URLs. Here we poll it at
// start, every poll_seconds and when the window is activated, download each
// file once, check its SHA-256, keep it in a local cache (capped), and show an
// ad only after its file is complete. Offline, the last manifest is shown.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../common.dart';
import '../consts.dart';
import '../models/platform_model.dart';

const int _kCacheLimitBytes = 300 * 1024 * 1024;

class RiqxAdItem {
  final int id;
  final String type; // image | gif | video
  final String url;
  final String sha256;
  final int size;
  final int? width;
  final int? height;
  final int durationMs;
  final String? link;
  final File file;

  RiqxAdItem._(this.id, this.type, this.url, this.sha256, this.size, this.width,
      this.height, this.durationMs, this.link, this.file);

  static RiqxAdItem? fromJson(Map<String, dynamic> j, Directory dir) {
    final url = j['url'];
    final sha = j['sha256'];
    if (url is! String || sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      return null;
    }
    final ext = Uri.parse(url).path.split('.').last.toLowerCase();
    if (!RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext)) return null;
    return RiqxAdItem._(
      (j['id'] as num?)?.toInt() ?? 0,
      (j['type'] as String?) ?? 'image',
      url,
      sha,
      (j['size'] as num?)?.toInt() ?? 0,
      (j['width'] as num?)?.toInt(),
      (j['height'] as num?)?.toInt(),
      (j['duration_ms'] as num?)?.toInt() ?? 8000,
      (j['link'] as String?)?.isNotEmpty == true ? j['link'] as String : null,
      File('${dir.path}${Platform.pathSeparator}$sha.$ext'),
    );
  }

  bool get isVideo => type == 'video';

  double? get aspect =>
      (width != null && height != null && height! > 0) ? width! / height! : null;
}

class RiqxAds {
  RiqxAds._();
  static final RiqxAds instance = RiqxAds._();

  /// slot -> ads whose files are complete and verified, in display order.
  final ValueNotifier<Map<String, List<RiqxAdItem>>> ready = ValueNotifier({});

  Directory? _dir;
  String? _etag;
  String? _lang;
  int _pollSeconds = 600;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool _started = false;
  bool _busy = false;

  void start() {
    if (_started) return;
    _started = true;
    () async {
      await _loadCached();
      await check();
    }();
    Timer.periodic(const Duration(seconds: 60), (_) {
      if (DateTime.now().difference(_lastCheck).inSeconds >= _pollSeconds) {
        check();
      }
    });
  }

  /// Window activated / app resumed: re-check, at most every 30 s.
  void onActivated() {
    if (DateTime.now().difference(_lastCheck).inSeconds >= 30) check();
  }

  String _currentLang() {
    final saved = bind.mainGetLocalOption(key: kCommConfKeyLang);
    final code = (saved.isEmpty || saved == 'default') ? localeName : saved;
    return code.toLowerCase().startsWith('fa') ? 'fa' : 'en';
  }

  Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}riqx_ads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  File _manifestFile(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}manifest.json');

  Future<void> _loadCached() async {
    try {
      final dir = await _cacheDir();
      final f = _manifestFile(dir);
      if (!await f.exists()) return;
      final saved = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _etag = saved['etag'] as String?;
      _lang = saved['lang'] as String?;
      await _apply(saved['manifest'] as Map<String, dynamic>, dir, download: false);
    } catch (e) {
      debugPrint('riqx ads: cached manifest unreadable: $e');
    }
  }

  Future<void> check() async {
    if (_busy) return;
    _busy = true;
    _lastCheck = DateTime.now();
    try {
      final api = (await bind.mainGetApiServer()).trim();
      if (api.isEmpty) return;
      final lang = _currentLang();
      final dir = await _cacheDir();
      final headers = <String, String>{};
      if (_etag != null && _lang == lang) headers['If-None-Match'] = _etag!;
      final resp = await http
          .get(Uri.parse('$api/api/riqx/ads?lang=$lang'), headers: headers)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 304) {
        // Unchanged; still finish any download an earlier run left behind.
        await _loadCached();
        return;
      }
      if (resp.statusCode != 200) return;
      final manifest = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      await _apply(manifest, dir, download: true);
      _etag = resp.headers['etag'];
      _lang = lang;
      await _manifestFile(dir).writeAsString(
          jsonEncode({'etag': _etag, 'lang': lang, 'manifest': manifest}));
    } catch (e) {
      debugPrint('riqx ads: check failed: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _apply(Map<String, dynamic> manifest, Directory dir,
      {required bool download}) async {
    final poll = (manifest['poll_seconds'] as num?)?.toInt();
    if (poll != null && poll >= 60) _pollSeconds = poll;

    final slots = (manifest['slots'] as Map?) ?? {};
    final result = <String, List<RiqxAdItem>>{};
    final keep = <String>{'manifest.json'};
    var budget = _kCacheLimitBytes;

    for (final slot in ['ads1', 'ads2']) {
      final items = <RiqxAdItem>[];
      for (final raw in (slots[slot] as List?) ?? const []) {
        if (raw is! Map) continue;
        final item = RiqxAdItem.fromJson(Map<String, dynamic>.from(raw), dir);
        if (item == null) continue;
        if (item.size > budget) continue;
        budget -= item.size;
        keep.add(item.file.uri.pathSegments.last);
        if (!await item.file.exists() && download) {
          await _download(item);
        }
        if (await item.file.exists()) items.add(item);
      }
      result[slot] = items;
    }
    ready.value = result;

    if (download) {
      // Drop files no longer in the manifest (and half-downloads).
      await for (final e in dir.list()) {
        final name = e.uri.pathSegments.last;
        if (e is File && !keep.contains(name)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _download(RiqxAdItem item) async {
    final tmp = File('${item.file.path}.part');
    try {
      final resp = await http.get(Uri.parse(item.url)).timeout(const Duration(minutes: 5));
      if (resp.statusCode != 200) return;
      if (sha256.convert(resp.bodyBytes).toString() != item.sha256) {
        debugPrint('riqx ads: hash mismatch for ${item.url}');
        return;
      }
      await tmp.writeAsBytes(resp.bodyBytes, flush: true);
      await tmp.rename(item.file.path);
    } catch (e) {
      debugPrint('riqx ads: download failed: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }
}

/// One ad slot. Shows nothing until it has a complete ad; rotates several.
class RiqxAdSlot extends StatefulWidget {
  final String slot;
  final double fallbackAspect;
  final double maxHeight;
  final Alignment alignment;

  const RiqxAdSlot(
      {Key? key,
      required this.slot,
      required this.fallbackAspect,
      this.maxHeight = double.infinity,
      this.alignment = Alignment.center})
      : super(key: key);

  @override
  State<RiqxAdSlot> createState() => _RiqxAdSlotState();
}

class _RiqxAdSlotState extends State<RiqxAdSlot>
    with WindowListener, WidgetsBindingObserver {
  static bool _mediaKitReady = false;

  int _index = 0;
  Timer? _timer;
  Player? _player;
  VideoController? _video;
  StreamSubscription? _completed;
  String? _shownKey;

  @override
  void initState() {
    super.initState();
    RiqxAds.instance.start();
    RiqxAds.instance.ready.addListener(_onReady);
    if (isDesktop) {
      windowManager.addListener(this);
    } else {
      WidgetsBinding.instance.addObserver(this);
    }
    _onReady();
  }

  @override
  void dispose() {
    RiqxAds.instance.ready.removeListener(_onReady);
    if (isDesktop) {
      windowManager.removeListener(this);
    } else {
      WidgetsBinding.instance.removeObserver(this);
    }
    _timer?.cancel();
    _disposeVideo();
    super.dispose();
  }

  @override
  void onWindowFocus() => RiqxAds.instance.onActivated();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) RiqxAds.instance.onActivated();
  }

  List<RiqxAdItem> get _items => RiqxAds.instance.ready.value[widget.slot] ?? const [];

  void _onReady() {
    final items = _items;
    if (items.isEmpty) {
      _timer?.cancel();
      _disposeVideo();
      if (mounted) setState(() => _shownKey = null);
      return;
    }
    if (_index >= items.length) _index = 0;
    _show();
  }

  void _show() {
    final items = _items;
    if (items.isEmpty) return;
    final item = items[_index % items.length];
    final key = '${item.id}:${item.sha256}';
    if (key == _shownKey) return;
    _shownKey = key;
    _timer?.cancel();
    _disposeVideo();

    if (item.isVideo) {
      try {
        if (!_mediaKitReady) {
          MediaKit.ensureInitialized();
          _mediaKitReady = true;
        }
        final player = Player();
        _player = player;
        _video = VideoController(player);
        player.setVolume(0);
        player.setPlaylistMode(items.length == 1 ? PlaylistMode.single : PlaylistMode.none);
        _completed = player.stream.completed.listen((done) {
          if (done && items.length > 1) _next();
        });
        player.open(Media(item.file.uri.toString()));
      } catch (e) {
        debugPrint('riqx ads: video failed: $e');
        _timer = Timer(const Duration(seconds: 2), _next);
      }
    } else if (items.length > 1) {
      _timer = Timer(Duration(milliseconds: item.durationMs.clamp(3000, 300000)), _next);
    }
    if (mounted) setState(() {});
  }

  void _next() {
    if (!mounted) return;
    _index = (_index + 1) % (_items.isEmpty ? 1 : _items.length);
    _shownKey = null;
    _show();
  }

  void _disposeVideo() {
    _completed?.cancel();
    _completed = null;
    _player?.dispose();
    _player = null;
    _video = null;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty || _shownKey == null) return const SizedBox.shrink();
    final item = items[_index % items.length];
    final aspect = item.aspect ?? widget.fallbackAspect;

    final Widget media = item.isVideo && _video != null
        ? Video(controller: _video!, controls: NoVideoControls, fill: Colors.transparent)
        : Image.file(item.file,
            key: ValueKey(item.file.path),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink());

    Widget child = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(aspectRatio: aspect, child: media),
    );
    if (item.link != null) {
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => launchUrl(Uri.parse(item.link!), mode: LaunchMode.externalApplication),
          child: child,
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final maxH = constraints.maxHeight.isFinite
          ? (constraints.maxHeight < widget.maxHeight ? constraints.maxHeight : widget.maxHeight)
          : widget.maxHeight;
      // Too little room to be readable: show nothing rather than a sliver.
      if (maxH.isFinite && maxH < 48) return const SizedBox.shrink();
      return Align(
        alignment: widget.alignment,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH, maxWidth: constraints.maxWidth),
          child: child,
        ),
      );
    });
  }
}
