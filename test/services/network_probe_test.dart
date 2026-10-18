import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/downloads/network_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginNetworkProbe', () {
    test('refresh survives a connectivity plugin that cannot answer', () async {
      // The regression this guards: the platform channel is not wired up in a
      // widget-test environment, so `checkConnectivity` throws
      // MissingPluginException. Refresh used to let that escape, and since it
      // is called from a connectivity-change listener the error became an
      // unhandled async error. Every other plugin call in the app is wrapped.
      final probe = PluginNetworkProbe();

      // No reading yet is "unknown", and unknown counts as metered.
      expect(probe.mayStart(wifiOnly: true), isFalse);

      await probe.refresh(); // Must not throw.

      // The failed reading leaves the last answer standing — still nothing,
      // so the conservative "unknown is metered" answer holds.
      expect(probe.mayStart(wifiOnly: true), isFalse);
      expect(
        probe.mayStart(wifiOnly: false),
        isTrue,
        reason: 'no wifi preference, no gate',
      );
    });
  });
}
