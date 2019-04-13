import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';
import 'package:graphql_flutter/src/cache/normalized_in_memory.dart'
    show Normalizer;
import 'package:graphql_flutter/src/cache/optimistic.dart';

class ObservableCache extends OptimisticCache {
  final Map<String, BehaviorSubject<dynamic>> observing =
      <String, BehaviorSubject<dynamic>>{};

  /// returns an rx `BehaviorSubject` observing `key`
  BehaviorSubject<dynamic> observe(String key) {
    observing.putIfAbsent(
      key,
      () => BehaviorSubject<dynamic>.seeded(
            read(key),
            onCancel: () => observing.remove(key),
          ),
    );
    return observing[key];
  }

  void _observeChange(String key) {
    final BehaviorSubject<dynamic> subject = observing[key];
    subject?.add(read(key));
  }

  @override
  void writeInto(
    String key,
    Object value,
    Map<String, Object> into, [
    Normalizer normalizer,
  ]) {
    super.writeInto(key, value, data, normalizer);
    _observeChange(key);
  }
}
