import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lets real asynchronous I/O settle inside a widget test.
///
/// `testWidgets` runs the body in a fake-async zone, so a `Future` that depends
/// on the actual filesystem — Hive's disk writes, the library page's
/// `File.exists()` probe — never completes and the test hangs rather than
/// failing. Anything whose state comes from a real file operation has to go
/// through one of these helpers.
///
/// Two things are deliberately *not* done for you:
///
/// - Seeding Hive belongs in `setUp`, which is outside the fake-async zone
///   already. Doing it in the test body hangs even with these helpers, because
///   the awaited write never resolves before a helper is ever reached.
///   [withIo] exists for the cases where the data genuinely differs per test.
/// - Widgets that animate forever (an indeterminate progress bar, for example)
///   still break `pumpAndSettle`, so those tests should pump explicitly.
Future<void> settleIo(WidgetTester tester, {int rounds = 20}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < rounds; i++) {
      // Alternate a frame advance with real wall-clock time, so a pending
      // filesystem future can complete and its `setState` can be picked up by
      // the following pump.
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pump();
}

/// Pumps frames and real time until [done] holds, failing if it never does.
///
/// Use this when work is *started* inside the fake-async zone — a Hive write
/// kicked off from a button callback, say. Its completion is scheduled against
/// fake time, so it only lands once real time passes while frames keep coming.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int rounds = 50,
}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < rounds; i++) {
      if (done()) return;
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await tester.pump();
  if (!done()) {
    throw StateError(
      'pumpUntil exhausted $rounds rounds waiting for a condition',
    );
  }
}

/// Runs real async work from inside a test body.
///
/// See the note on [settleIo]: a bare `await service.add(...)` in a test body
/// hangs the run instead of failing it.
Future<T> withIo<T>(WidgetTester tester, Future<T> Function() work) async {
  final result = await tester.runAsync(work);
  // runAsync returns T? because it cannot distinguish a null result from "no
  // result". A null is legitimate when T admits null, so only reject it when T
  // does not — otherwise a void-returning helper would always throw.
  if (result == null && null is! T) {
    throw StateError('withIo<$T> completed with null');
  }
  return result as T;
}

/// Writes a file of [size] bytes under [dir] and returns its path.
String writeFile(Directory dir, String name, {int size = 1}) {
  final path = '${dir.path}/$name';
  File(path).writeAsBytesSync(List.filled(size, 0));
  return path;
}
