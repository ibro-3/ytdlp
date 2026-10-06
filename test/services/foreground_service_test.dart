import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/foreground/foreground_service.dart';

/// Records what the service asked the driver to do and lets each test choose a
/// host it should pretend to be on.
class _FakeDriver implements ForegroundTaskDriver {
  _FakeDriver({this.supported = true}) : _running = false;

  final bool supported;
  bool _running;

  int startCalls = 0;
  int updateCalls = 0;
  int stopCalls = 0;
  ({String title, String headline})? lastStart;
  ({String title, String headline})? lastUpdate;

  @override
  bool get isSupportedHost => supported;

  @override
  Future<bool> isRunning() async => _running;

  @override
  Future<void> start({required String title, required String headline}) async {
    startCalls++;
    _running = true;
    lastStart = (title: title, headline: headline);
  }

  @override
  Future<void> update({required String title, required String headline}) async {
    updateCalls++;
    lastUpdate = (title: title, headline: headline);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _running = false;
  }
}

void main() {
  group('off Android', () {
    late _FakeDriver driver;
    late ForegroundService service;

    setUp(() {
      driver = _FakeDriver(supported: false);
      service = ForegroundService.forTesting(driver);
    });

    test('never starts, updates or stops', () async {
      await service.startService(title: 'X', progress: 0.5);
      await service.updateService(title: 'X', progress: 0.6);
      await service.stopService();

      expect(driver.startCalls, 0);
      expect(driver.updateCalls, 0);
      expect(driver.stopCalls, 0);
    });

    test('reports the service as not running', () async {
      expect(await service.isRunning, isFalse);
    });
  });

  group('on Android', () {
    late _FakeDriver driver;
    late ForegroundService service;

    setUp(() {
      driver = _FakeDriver();
      service = ForegroundService.forTesting(driver);
    });

    test('starts the service with a percentage headline', () async {
      await service.startService(title: 'A title', progress: 0.42);

      expect(driver.startCalls, 1);
      expect(driver.lastStart?.headline, 'Downloading… 42%');
      expect(driver.lastStart?.title, 'A title');
    });

    test(
      'a second start while running only refreshes the notification',
      () async {
        // The plugin answers a redundant start contract with
        // ForgroundServiceDidNotStartInTime, so an already-running service must be
        // updated rather than re-started.
        await service.startService(title: 'Title', progress: 0.1);
        await service.startService(title: 'Title', progress: 0.5);

        expect(driver.startCalls, 1);
        expect(driver.updateCalls, 1);
        expect(driver.lastUpdate?.headline, 'Downloading… 50%');
      },
    );

    test('concurrent starts issue only one start contract', () async {
      // `DownloadManager` calls this per task without awaiting, so with a
      // concurrency above one two callers both saw "not running" and both
      // issued a start — the redundant contract the plugin rejects.
      await Future.wait([
        service.startService(title: 'A', progress: 0.1),
        service.startService(title: 'B', progress: 0.2),
        service.startService(title: 'C', progress: 0.3),
      ]);

      expect(driver.startCalls, 1, reason: 'one start, the rest refresh');
    });

    test('stop is a no-op when the service never started', () async {
      await service.stopService();

      expect(driver.stopCalls, 0);
    });

    test('stop stops a running service', () async {
      await service.startService(title: 'T', progress: 0.1);
      await service.stopService();

      expect(driver.stopCalls, 1);
      expect(await service.isRunning, isFalse);
    });

    test(
      'progress is clamped and rounded, never a two-hundred percent',
      () async {
        await service.startService(title: 'T', progress: 1.7);
        expect(driver.lastStart?.headline, 'Downloading… 100%');

        await service.stopService();
        driver = _FakeDriver();
        service = ForegroundService.forTesting(driver);
        await service.startService(title: 'T', progress: -0.2);
        expect(driver.lastStart?.headline, 'Downloading… 0%');
      },
    );
  });
}
