import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'core/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  final historyBox = await Hive.openBox<dynamic>('history');
  runApp(
    ProviderScope(
      overrides: [historyBoxProvider.overrideWithValue(historyBox)],
      child: const App(),
    ),
  );
}
