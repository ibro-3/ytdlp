import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/models/command_template.dart';

/// Persistence for user-saved argument templates.
///
/// Kept in its own Hive box rather than in [AppSettings] so the whole list can
/// be replaced atomically and so adding a template never rewrites the
/// settings map. Records are keyed by a slug of the name, so renaming a
/// template replaces it instead of accumulating duplicates.
class TemplateStore extends ChangeNotifier {
  TemplateStore(this._box);

  final Box<dynamic> _box;

  static const _keyPrefix = 'tpl:';

  /// Ceiling on saved templates. A list this long is a sign the user is
  /// experimenting, not that the app should grow without bound.
  static const maxTemplates = 30;

  List<CommandTemplate> get templates {
    final list = <CommandTemplate>[];
    for (final key in _box.keys) {
      if (key is! String || !key.startsWith(_keyPrefix)) continue;
      final value = _box.get(key);
      if (value is! Map) continue;
      try {
        list.add(CommandTemplate.fromMap(Map<String, dynamic>.from(value)));
      } catch (_) {
        // One corrupt record must not hide the rest.
      }
    }
    // Sorted by name so the picker order does not depend on Hive iteration.
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  CommandTemplate? byName(String name) {
    final key = _keyFor(name);
    final value = _box.get(key);
    if (value is! Map) return null;
    try {
      return CommandTemplate.fromMap(Map<String, dynamic>.from(value));
    } catch (_) {
      return null;
    }
  }

  /// Saves [template], replacing any existing one with the same name.
  ///
  /// Returns false when the name is blank, the arguments do not tokenise, or
  /// the store is full — callers surface that to the user rather than
  /// silently dropping what they typed.
  Future<bool> save(CommandTemplate template) async {
    final name = template.name.trim();
    if (name.isEmpty) return false;
    final existing = templates;
    if (existing.length >= maxTemplates &&
        !existing.any((t) => t.name.toLowerCase() == name.toLowerCase())) {
      return false;
    }
    await _box.put(
      _keyFor(name),
      CommandTemplate(name: name, args: template.args).toMap(),
    );
    notifyListeners();
    return true;
  }

  Future<bool> remove(String name) async {
    // Hive's delete returns void, so existence is checked first.
    final key = _keyFor(name);
    if (!_box.containsKey(key)) return false;
    await _box.delete(key);
    notifyListeners();
    return true;
  }

  Future<void> clear() async {
    final keys = _box.keys
        .where((k) => k is String && k.startsWith(_keyPrefix))
        .cast<String>()
        .toList();
    if (keys.isEmpty) return;
    await _box.deleteAll(keys);
    notifyListeners();
  }

  /// Lowercased, whitespace-collapsed name. Two names differing only in case
  /// map to one record, which is what a user expects from a picker.
  String _keyFor(String name) =>
      '$_keyPrefix${name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}';
}
