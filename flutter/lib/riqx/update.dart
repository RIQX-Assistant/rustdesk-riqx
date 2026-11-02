// RIQX: a new version, from inside the app (docs/12-app-update.md).
//
// The console's {api}/api/riqx/update lists what /downloads offers. When it has
// a newer version than this build, a strip appears across the top of the main
// window.
//
//  - Windows, installed from the MSI: «Install» downloads the MSI, checks its
//    SHA-256 and its Ed25519 signature, asks once (the install closes the app
//    and drops any session), then runs msiexec /passive. Windows asks for its
//    permission and shows the progress; the MSI closes the app and starts it
//    again, as it does for a manual install.
//  - Android: «Install» downloads the APK for this phone's ABI, checks its
//    SHA-256 and hands it to Android's own install screen. Android accepts it
//    only if it carries the same signing key as the installed app.
//  - macOS, and Windows not installed from the MSI: «Download» opens the link.
//
// Nothing installs without a click. A build started without a riqx-* tag knows
// no version of its own and never shows the strip.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../common.dart';
import '../consts.dart';
import '../models/platform_model.dart';
import 'update_core.dart';

const _kCheckEvery = Duration(hours: 1);
const _kCheckOnFocusEvery = Duration(minutes: 10);

enum _Install { msi, apk, link }

class RiqxUpdate extends ChangeNotifier {
  RiqxUpdate._();
  static final RiqxUpdate instance = RiqxUpdate._();

  String _current = '';
  String _api = '';
  bool _started = false;
  bool _checking = false;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  RiqxUpdateFile? file;
  _Install _install = _Install.link;
  double? progress; // 0..1 while the file downloads
  bool preparing = false; // checks and the question between download and install
  bool installing = false; // handed to Windows or Android
  bool needsPermission = false; // Android's «install unknown apps» screen opened
  bool dismissed = false;
  RiqxUpdateError? error;

  void start() {
    if (_started) return;
    _started = true;
    _current = bind.mainGetCommonSync(key: 'riqx-version');
    if (!riqxIsVersion(_current)) return;
    () async {
      await _removeOldDownloads();
      await check();
    }();
    Timer.periodic(const Duration(minutes: 1), (_) {
      if (DateTime.now().difference(_lastCheck) >= _kCheckEvery) check();
    });
  }

  /// Window activated / app resumed.
  void onActivated() {
    if (!riqxIsVersion(_current)) return;
    if (DateTime.now().difference(_lastCheck) >= _kCheckOnFocusEvery) check();
  }

  Future<void> check() async {
    if (_checking || progress != null || preparing || installing) return;
    _checking = true;
    _lastCheck = DateTime.now();
    try {
      final api = (await bind.mainGetApiServer()).trim();
      if (api.isEmpty) return;
      final reply = await http
          .get(Uri.parse('$api/api/riqx/update'))
          .timeout(const Duration(seconds: 30));
      if (reply.statusCode != 200) return;
      final body = jsonDecode(utf8.decode(reply.bodyBytes));
      final rows = body is Map ? body['files'] : null;
      if (rows is! List) return;
      final files = rows
          .map(RiqxUpdateFile.fromJson)
          .whereType<RiqxUpdateFile>()
          .toList();
      _api = api;
      await _apply(files);
    } catch (e) {
      // Offline, or the console is restarting: whatever the strip says stands.
      debugPrint('riqx update check: $e');
    } finally {
      _checking = false;
    }
  }

  Future<void> _apply(List<RiqxUpdateFile> files) async {
    RiqxUpdateFile? picked;
    var install = _Install.link;
    if (isWindows) {
      picked = riqxPickFile(files,
          current: _current,
          platform: 'windows',
          archs: const ['x86_64'],
          ext: 'msi');
      final msi = bind.mainGetCommonSync(key: 'riqx-msi-installed') == 'true';
      // The signature, not only the checksum: the checksum comes from the same
      // server as the file, and the installer runs as administrator.
      if (msi && picked != null && picked.signature.isNotEmpty) {
        install = _Install.msi;
      }
    } else if (isAndroid) {
      picked = riqxPickFile(files,
          current: _current,
          platform: 'android',
          archs: [...await _androidArch(), 'universal'],
          ext: 'apk');
      install = _Install.apk;
    } else if (isMacOS) {
      picked = riqxPickFile(files,
          current: _current,
          platform: 'macos',
          archs: [Abi.current() == Abi.macosArm64 ? 'arm64' : 'x86_64'],
          ext: 'dmg');
    }
    if (picked?.version != file?.version) {
      dismissed = false;
      error = null;
      needsPermission = false;
    }
    file = picked;
    _install = install;
    notifyListeners();
  }

  Future<List<String>> _androidArch() async {
    try {
      final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
      const names = {
        'arm64-v8a': 'arm64',
        'armeabi-v7a': 'armv7',
        'x86_64': 'x86_64',
      };
      final first = names[abis.isEmpty ? '' : abis.first];
      return first == null ? const [] : [first];
    } catch (_) {
      return const [];
    }
  }

  void dismiss() {
    dismissed = true;
    notifyListeners();
  }

  Future<Directory> _folder() async {
    final base = await getTemporaryDirectory();
    return Directory('${base.path}${Platform.pathSeparator}riqx_update');
  }

  /// Whatever an earlier update left: by now it is installed or out of date.
  Future<void> _removeOldDownloads() async {
    try {
      final dir = await _folder();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('riqx update cleanup: $e');
    }
  }

  /// The strip's button.
  Future<void> press() async {
    final f = file;
    if (f == null || progress != null || preparing || installing) return;
    if (_install == _Install.link) {
      // macOS takes the file; Windows gets the page, it has to choose.
      final link = isMacOS ? '$_api/downloads/${f.id}' : '$_api/downloads';
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
      return;
    }
    error = null;
    needsPermission = false;
    notifyListeners();
    try {
      final target = await _fetch(f);
      if (_install == _Install.msi) {
        await _installMsi(f, target);
      } else {
        await _installApk(f, target);
      }
    } on RiqxUpdateError catch (e) {
      error = e;
    } catch (e) {
      // Whatever happens, the strip must not stay stuck without a button.
      debugPrint('riqx update: $e');
      error = const RiqxUpdateError('نسخهٔ تازه نصب نشد؛ دوباره بزنید.',
          'The new version was not installed. Please try again.');
    } finally {
      progress = null;
      preparing = false;
      if (!_androidScreenOpen) installing = false;
      notifyListeners();
    }
  }

  bool _androidScreenOpen = false;

  /// The checked file, downloaded now unless an earlier press already did (a
  /// refused permission prompt must not mean downloading it again).
  Future<File> _fetch(RiqxUpdateFile f) async {
    final dir = await _folder();
    if (!await dir.exists()) await dir.create(recursive: true);
    final target =
        File('${dir.path}${Platform.pathSeparator}RIQX-${f.version}.${f.ext}');
    if (!await riqxFileMatches(target, f.sha256)) {
      progress = 0;
      notifyListeners();
      final client = http.Client();
      try {
        await riqxDownload(client, Uri.parse('$_api/downloads/${f.id}'), target,
            f.sha256, f.size, (p) {
          if ((p * 100).floor() != ((progress ?? 0) * 100).floor()) {
            progress = p;
            notifyListeners();
          }
        });
      } finally {
        client.close();
      }
      progress = null;
    }
    return target;
  }

  Future<void> _installMsi(RiqxUpdateFile f, File msi) async {
    preparing = true;
    notifyListeners();
    // Right before it runs, on the bytes that are on disk now.
    final verified = await riqxFileMatches(msi, f.sha256) &&
        bind.mainGetCommonSync(
                key:
                    'riqx-verify-update:${f.version}:${f.sha256}:${f.signature}') ==
            'true';
    if (!verified) {
      try {
        await msi.delete();
      } on IOException catch (_) {}
      throw const RiqxUpdateError(
          'امضای نسخهٔ تازه درست نیست و نصب نشد؛ آن را از صفحهٔ دانلود بگیرید.',
          'The signature of the new version is not valid, so it was not installed. Please get it from the download page.');
    }
    if (!await _confirmInstall(f)) return;
    preparing = false;
    installing = true;
    notifyListeners();
    final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    // A log from the first day: a failure on someone's machine is otherwise
    // impossible to read afterwards.
    final log =
        '${msi.parent.parent.path}${Platform.pathSeparator}riqx-update.log';
    final process = await Process.start('$windows\\System32\\msiexec.exe', [
      '/i',
      msi.path,
      '/passive',
      '/norestart',
      'REBOOT=ReallySuppress',
      '/L*V',
      log,
    ]);
    // On success the MSI has closed this app long before this returns.
    final code = await process.exitCode;
    if (code == 0 || code == 3010 || code == 1641) {
      throw const RiqxUpdateError(
          'نسخهٔ تازه نصب شد؛ اپ را ببندید و دوباره باز کنید.',
          'The new version is installed. Please close the app and open it again.');
    }
    if (code == 1602) {
      throw const RiqxUpdateError(
          'اجازهٔ ویندوز داده نشد؛ برای نصب دوباره بزنید.',
          'Windows permission was refused. Press again to install.');
    }
    if (code == 1618) {
      throw const RiqxUpdateError(
          'نصب دیگری در ویندوز در حال اجراست؛ کمی بعد دوباره بزنید.',
          'Another installation is running. Please try again in a moment.');
    }
    throw RiqxUpdateError('نصب انجام نشد (کد $code). گزارش: ${_iso(log)}',
        'The installation failed (code $code). Log: $log');
  }

  Future<bool> _confirmInstall(RiqxUpdateFile f) {
    final fa = riqxUpdateLangIsFa();
    final done = Completer<bool>();
    gFFI.dialogManager.show((setState, close, context) {
      void answer(bool yes) {
        if (!done.isCompleted) done.complete(yes);
        close();
      }

      return CustomAlertDialog(
        title: Text(fa ? 'نصب نسخهٔ تازه' : 'Install the new version'),
        content: Text(fa
            ? 'نسخهٔ ${_iso(f.version)} آماده است.\n'
                'برای نصب، RIQX بسته و بعد از چند ثانیه دوباره باز می‌شود و اگر الان اتصالی دارید قطع می‌شود. ویندوز هم یک بار اجازه می‌خواهد.'
            : 'Version ${f.version} is ready.\n'
                'RIQX will close and open again after a few seconds, and any connection you have now will drop. Windows will ask for permission once.'),
        actions: [
          dialogButton(fa ? 'بعداً' : 'Later',
              onPressed: () => answer(false), isOutline: true),
          dialogButton(fa ? 'نصب' : 'Install', onPressed: () => answer(true)),
        ],
        onCancel: () => answer(false),
      );
    });
    return done.future;
  }

  Future<void> _installApk(RiqxUpdateFile f, File apk) async {
    if (!await riqxFileMatches(apk, f.sha256)) throw kRiqxErrHash;
    final result = await gFFI.invokeMethodWithResult<String>(
        'riqx_install_apk', {'path': apk.path});
    if (result == 'permission') {
      needsPermission = true;
    } else if (result == 'started') {
      // Android's own screen is on top now, and nothing here hears what it
      // decides. The strip gets its button back shortly after.
      installing = true;
      _androidScreenOpen = true;
      Timer(const Duration(seconds: 20), () {
        _androidScreenOpen = false;
        installing = false;
        notifyListeners();
      });
    } else {
      throw const RiqxUpdateError(
          'صفحهٔ نصب اندروید باز نشد؛ نسخهٔ تازه را از صفحهٔ دانلود بگیرید.',
          'Android\'s install screen did not open. Please get the new version from the download page.');
    }
  }
}

// Keeps a Latin version or path in order inside a right-to-left sentence.
String _iso(String latin) => '\u2066$latin\u2069';

bool riqxUpdateLangIsFa() {
  final saved = bind.mainGetLocalOption(key: kCommConfKeyLang);
  final code = (saved.isEmpty || saved == 'default') ? localeName : saved;
  return code.toLowerCase().startsWith('fa');
}

/// Across the top of the main window; takes no room while there is no update.
class RiqxUpdateStrip extends StatefulWidget {
  const RiqxUpdateStrip({Key? key}) : super(key: key);

  @override
  State<RiqxUpdateStrip> createState() => _RiqxUpdateStripState();
}

class _RiqxUpdateStripState extends State<RiqxUpdateStrip>
    with WindowListener, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    RiqxUpdate.instance.start();
    if (isDesktop) {
      windowManager.addListener(this);
    } else {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void dispose() {
    if (isDesktop) {
      windowManager.removeListener(this);
    } else {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  @override
  void onWindowFocus() => RiqxUpdate.instance.onActivated();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) RiqxUpdate.instance.onActivated();
  }

  String _text(RiqxUpdate u, RiqxUpdateFile f, bool fa) {
    if (u.installing) {
      if (isAndroid) {
        return fa
            ? 'صفحهٔ نصب اندروید باز شد؛ در آن «نصب» را بزنید.'
            : 'Android\'s install screen is open: press Install there.';
      }
      return fa
          ? 'در حال نصب… اگر ویندوز اجازه خواست، «Yes» را بزنید. اپ بسته و دوباره باز می‌شود.'
          : 'Installing… If Windows asks for permission, press Yes. The app will close and open again.';
    }
    if (u.progress != null) {
      final percent = '${(u.progress! * 100).floor()}%';
      return fa
          ? 'در حال دانلود نسخهٔ تازه: ${_iso(percent)}'
          : 'Downloading the new version: $percent';
    }
    if (u.preparing) {
      return fa
          ? 'نسخهٔ تازه دانلود شد؛ در حال آماده‌سازی نصب…'
          : 'Downloaded. Getting the installation ready…';
    }
    if (u.error != null) return fa ? u.error!.fa : u.error!.en;
    if (u.needsPermission) {
      return fa
          ? 'اجازهٔ «نصب برنامه‌های ناشناس» را به RIQX بدهید و دوباره «نصب» را بزنید.'
          : 'Allow RIQX to install unknown apps, then press Install again.';
    }
    return fa
        ? 'نسخهٔ تازهٔ RIQX آماده است (${_iso(f.version)})'
        : 'A new version of RIQX is ready (${f.version})';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: RiqxUpdate.instance,
      builder: (context, _) {
        final u = RiqxUpdate.instance;
        final f = u.file;
        if (f == null || u.dismissed) return const SizedBox.shrink();
        final fa = riqxUpdateLangIsFa();
        final busy = u.progress != null || u.preparing || u.installing;
        final link = u._install == _Install.link;
        return RiqxUpdateBar(
          text: _text(u, f, fa),
          progress: u.progress,
          busy: busy,
          isError: u.error != null,
          action: busy
              ? null
              : (link ? (fa ? 'دانلود' : 'Download') : (fa ? 'نصب' : 'Install')),
          onAction: busy ? null : u.press,
          onClose: busy ? null : u.dismiss,
        );
      },
    );
  }
}
