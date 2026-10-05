import 'package:connectivity_plus/connectivity_plus.dart';

/// Whether the current network is suitable for the downloads the user
/// asked for.
///
/// Split from [DownloadManager] behind this seam so the "only download
/// on unmetered" rule can be tested on any host — the plugin's platform
/// channel is the part that cannot.
///
/// [mayStart] is synchronous on purpose: the scheduler consults it on
/// every pump, and a pump must never await. The probe therefore answers
/// from the last connectivity it saw, refreshed by [refresh] at startup
/// and on every connectivity change, so the answer is never more than
/// one event stale.
abstract interface class NetworkProbe {
  /// Whether starting a new download right now honors [wifiOnly] under
  /// the current connectivity.
  bool mayStart({required bool wifiOnly});

  /// Re-reads the platform connectivity so [mayStart] is not stale.
  Future<void> refresh();
}

/// Talks to `connectivity_plus`.
class PluginNetworkProbe implements NetworkProbe {
  List<ConnectivityResult> _last = const [];

  @override
  bool mayStart({required bool wifiOnly}) {
    if (!wifiOnly) return true;
    // No reading yet means "unknown", and unknown is treated as metered:
    // for a user who asked for unmetered-only, holding a download is
    // cheaper than burning mobile data by mistake.
    if (_last.isEmpty) return false;
    return _last.any(
      (c) => c == ConnectivityResult.wifi || c == ConnectivityResult.ethernet,
    );
  }

  @override
  Future<void> refresh() async {
    _last = await Connectivity().checkConnectivity();
  }
}
