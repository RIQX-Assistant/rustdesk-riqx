// RIQX: the app's links to the console's public pages, /privacy and /Help.
// The console's address comes from the build, like the ads and the update
// strip, because this public source does not carry it (docs/13-public-pages.md).
import 'package:url_launcher/url_launcher_string.dart';

import '../models/platform_model.dart';
import 'update_core.dart';

Future<void> riqxOpenPanelPage(String path) async {
  final url = riqxPanelPageUrl(await bind.mainGetApiServer(), path);
  await launchUrlString(url, mode: LaunchMode.externalApplication);
}
