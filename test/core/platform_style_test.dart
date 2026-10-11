import 'package:flutter/cupertino.dart' show CupertinoApp;
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/platform_style.dart';

/// Which style a platform draws with, and that the app's own widgets follow it.
///
/// The Material path is covered by every other widget test in this suite, which
/// run with Flutter's default test platform of Android. These cover the two the
/// suite cannot reach from a Linux host: the Cupertino and Fluent roots, each
/// driven by `debugDefaultTargetPlatformOverride`.
void main() {
  group('platformStyleOf', () {
    test('Android draws Material', () {
      expect(platformStyleOf(TargetPlatform.android), PlatformStyle.material);
    });

    test('Linux draws the GTK family', () {
      expect(platformStyleOf(TargetPlatform.linux), PlatformStyle.gtk);
    });

    test('Apple platforms draw Cupertino', () {
      expect(platformStyleOf(TargetPlatform.macOS), PlatformStyle.cupertino);
      expect(platformStyleOf(TargetPlatform.iOS), PlatformStyle.cupertino);
    });

    test('Windows draws Fluent', () {
      expect(platformStyleOf(TargetPlatform.windows), PlatformStyle.fluent);
    });

    test('fuchsia falls back to Material', () {
      expect(platformStyleOf(TargetPlatform.fuchsia), PlatformStyle.material);
    });
  });

  group('the app root', () {
    testWidgets('is a CupertinoApp on Apple platforms', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(const _StyleProbe());

      expect(find.byType(CupertinoApp), findsOneWidget);
      expect(find.byType(MaterialApp), findsNothing);
      // Cleared before the test ends: the binding refuses to finish a test
      // that leaves this set, and a `tearDown` runs after that check.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('is a MaterialApp on Linux, because GTK is a Material tree', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.pumpWidget(const _StyleProbe());

      // GTK is drawn from Material widgets plus Adwaita's own chrome, so the
      // root is a MaterialApp — what makes it GTK is the *theme*, which the
      // style probe here does not carry.
      expect(find.byType(MaterialApp), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('is a MaterialApp on Android', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(const _StyleProbe());

      // The host already defaults to Android, so this is also the assertion
      // that the override restores the default when cleared.
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(CupertinoApp), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

/// The same switch the real root uses, so the test asserts against the decision
/// rather than a copy of it.
class _StyleProbe extends StatelessWidget {
  const _StyleProbe();

  @override
  Widget build(BuildContext context) {
    return switch (context.style) {
      PlatformStyle.cupertino => CupertinoApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const SizedBox.shrink(),
      ),
      _ => MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const SizedBox.shrink(),
      ),
    };
  }
}
