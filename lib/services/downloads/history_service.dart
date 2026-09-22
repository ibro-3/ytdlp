import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/models/download_record.dart';

class HistoryService extends ChangeNotifier {
  HistoryService(this._box);
  final Box<dynamic> _box;
  List<DownloadRecord> _records = [];

  List<DownloadRecord> get records => List.unmodifiable(_records);

  void init() {
    _records =
        _box.values
            .map(
              (e) =>
                  DownloadRecord.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> add(DownloadRecord record) async {
    await _box.put(record.id, record.toMap());
    _records.insert(0, record);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await _box.delete(id);
    _records.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  Future<void> clear() async {
    await _box.clear();
    _records.clear();
    notifyListeners();
  }
}
