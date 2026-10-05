import 'dart:async';

import 'package:hive/hive.dart';

/// An in-memory `Box<dynamic>`, for tests whose page *writes* settings.
///
/// A real Hive box is the obvious choice and it deadlocks those tests. Any write
/// a test triggers is still in flight when the test body ends, `close()` flushes
/// it, and that flush is scheduled against the test's fake clock — which only
/// advances while frames are pumped. `tearDown` pumps nothing, so the close
/// never returns and the test times out rather than failing, which reads as a
/// hang with no clue as to why. Moving the close into `addTearDown` does not
/// rescue it either: `runAsync` is unavailable once the body has ended.
///
/// Keeping the writes in memory removes the flush entirely. `put` still resolves
/// asynchronously, so the code under test's own `await`s are exercised rather
/// than skipped — which is the part a synchronous stub would fake away, and the
/// part that matters for a page that writes a setting *before* rebuilding.
class MemoryBox extends Box<dynamic> {
  final Map<dynamic, dynamic> _values = {};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _values.containsKey(key) ? _values[key] : defaultValue;

  @override
  dynamic getAt(int index) => _values.values.elementAtOrNull(index);

  @override
  dynamic keyAt(int index) => _values.keys.elementAtOrNull(index);

  @override
  Future<void> put(dynamic key, dynamic value) async => _values[key] = value;

  @override
  Future<void> putAt(int index, dynamic value) async =>
      _values[_values.keys.elementAt(index)] = value;

  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) async =>
      _values.addAll(entries);

  @override
  Future<int> add(dynamic value) async {
    final key = 'key-${_values.length}';
    _values[key] = value;
    return _values.length - 1;
  }

  @override
  Future<Iterable<int>> addAll(Iterable<dynamic> values) async => [
    for (final v in values) await add(v),
  ];

  @override
  Future<void> delete(dynamic key) async => _values.remove(key);

  @override
  Future<void> deleteAt(int index) async =>
      _values.remove(_values.keys.elementAt(index));

  @override
  Future<void> deleteAll(Iterable<dynamic> keys) async {
    for (final key in keys) {
      _values.remove(key);
    }
  }

  @override
  Future<int> clear() async {
    final removed = _values.length;
    _values.clear();
    return removed;
  }

  @override
  Future<void> compact() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async => _values.clear();

  @override
  Future<void> deleteFromDisk() async => _values.clear();

  @override
  Stream<BoxEvent> watch({dynamic key}) => const Stream<BoxEvent>.empty();

  @override
  bool get isOpen => true;

  @override
  String get name => 'memory';

  @override
  String? get path => null;

  @override
  bool get lazy => false;

  @override
  Iterable<dynamic> get keys => _values.keys;

  @override
  Iterable<dynamic> get values => _values.values;

  @override
  Iterable<dynamic> valuesBetween({dynamic startKey, dynamic endKey}) =>
      const Iterable<dynamic>.empty();

  @override
  Map<dynamic, dynamic> toMap() => Map<dynamic, dynamic>.from(_values);

  @override
  bool containsKey(dynamic key) => _values.containsKey(key);

  @override
  int get length => _values.length;

  @override
  bool get isEmpty => _values.isEmpty;

  @override
  bool get isNotEmpty => _values.isNotEmpty;
}
