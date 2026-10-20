import 'dart:convert';

/// A field-level replica with a hybrid logical clock and durable deletions.
class SyncReplica {
  SyncReplica(this.deviceId);
  final String deviceId;
  int clock = 0;
  final Map<String, Map<String, dynamic>> records = {};
  final Map<String, Map<String, dynamic>> recovery = {};
  Map<String, dynamic> _view = {};

  static int compare(Map a, Map b) {
    final order = ((a['clock'] as num?)?.toInt() ?? 0)
        .compareTo((b['clock'] as num?)?.toInt() ?? 0);
    return order != 0 ? order : '${a['device']}'.compareTo('${b['device']}');
  }

  static String canonical(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${canonical(value[key])}').join(',')}}';
    }
    if (value is List) return '[${value.map(canonical).join(',')}]';
    return jsonEncode(value);
  }

  void seed(Map<String, dynamic> values) {
    for (final entry in values.entries) {
      records.putIfAbsent(
          entry.key,
          () => {
                'clock': 0,
                'device': deviceId,
                'value': entry.value,
              });
    }
    acceptView(values);
  }

  void acceptView(Map<String, dynamic> values) {
    _view = jsonDecode(jsonEncode(values)) as Map<String, dynamic>;
  }

  bool capture(Map<String, dynamic> values, {int? nowMicros}) {
    final changed = {..._view.keys, ...values.keys}.where(
      (key) {
        final before = _view[key];
        final after = values[key];
        if (key.startsWith('session/') &&
            before is Map &&
            after is Map &&
            before['active'] is Map &&
            after['active'] is Map &&
            (before['active']['updatedAt'] == after['active']['updatedAt'] ||
                (before['active']['progress'] is Map &&
                    before['active']['progress']['id'] != null &&
                    before['active']['progress']['id'] ==
                        after['active']['progress']?['id']))) {
          // Derived card states and face changes cannot re-author an old
          // session. Only an actual local progress revision can do that.
          return false;
        }
        return canonical(before) != canonical(after);
      },
    ).toList();
    if (changed.isEmpty) return false;
    final wall = nowMicros ?? DateTime.now().toUtc().microsecondsSinceEpoch;
    clock = wall > clock ? wall : clock + 1;
    for (final key in changed) {
      records[key] = {'clock': clock, 'device': deviceId, 'value': values[key]};
    }
    acceptView(values);
    return true;
  }

  void _archive(String key, Map<String, dynamic> record) {
    recovery['$key@${record['clock']}@${record['device']}'] = record;
  }

  /// Reduce the entire retained causal frontier, never pairwise winners.
  /// Pairwise causal/primary/LWW comparisons are not transitive.
  void _resolveSession(String key) {
    final candidates = <String, Map<String, dynamic>>{};
    for (final entry in recovery.entries) {
      if (entry.key.startsWith('$key@')) {
        candidates[canonical(entry.value)] = entry.value;
      }
    }
    final local = records[key];
    if (local != null) candidates[canonical(local)] = local;
    var eligible = candidates.values.toList();
    if (eligible.isEmpty) return;
    final tombstones = eligible.where((r) => r['value'] == null).toList()
      ..sort(compare);
    if (tombstones.isNotEmpty) {
      final barrier = tombstones.last;
      eligible = eligible.where((r) => compare(r, barrier) > 0).toList();
      if (eligible.isEmpty) eligible = [barrier];
    }
    Map progress(Map r) {
      final value = r['value'];
      final active = value is Map ? value['active'] : null;
      return active is Map && active['progress'] is Map
          ? active['progress'] as Map
          : const {};
    }

    if (eligible.any((r) => progress(r)['schema'] == 1)) {
      eligible = eligible.where((r) => progress(r)['schema'] == 1).toList();
    }
    bool dominates(Map a, Map b) {
      final av = progress(a)['vector'] as Map? ?? const {};
      final bv = progress(b)['vector'] as Map? ?? const {};
      var greater = false;
      for (final k in {...av.keys, ...bv.keys}) {
        final x = (av[k] as num?)?.toInt() ?? 0;
        final y = (bv[k] as num?)?.toInt() ?? 0;
        if (x < y) return false;
        greater |= x > y;
      }
      return greater;
    }

    // Descendants have a strictly larger vector sum. Visit them first, so
    // long linear study histories do not require quadratic pair comparisons.
    int weight(Map r) => (progress(r)['vector'] as Map? ?? const {})
        .values
        .fold<int>(0, (sum, v) => sum + ((v as num?)?.toInt() ?? 0));
    eligible.sort((a, b) => weight(b).compareTo(weight(a)));
    final frontier = <Map<String, dynamic>>[];
    for (final candidate in eligible) {
      if (!frontier.any((other) => dominates(other, candidate))) {
        frontier.add(candidate);
      }
    }
    frontier.sort((a, b) {
      final ap = progress(a), bp = progress(b);
      final primaryOrder =
          '${ap['primary'] ?? ''}'.compareTo('${bp['primary'] ?? ''}');
      if (primaryOrder != 0) return primaryOrder;
      final primary = ap['primary'];
      final av = ap['vector'] as Map? ?? const {};
      final bv = bp['vector'] as Map? ?? const {};
      final lineage = ((av[primary] as num?)?.toInt() ?? 0)
          .compareTo((bv[primary] as num?)?.toInt() ?? 0);
      if (lineage != 0) return lineage;
      final aPrimary = ap['primary'] != null && ap['device'] == ap['primary'];
      final bPrimary = bp['primary'] != null && bp['device'] == bp['primary'];
      final preference = (aPrimary ? 1 : 0).compareTo(bPrimary ? 1 : 0);
      if (preference != 0) return preference;
      final clockOrder = compare(a, b);
      return clockOrder != 0
          ? clockOrder
          : canonical(a).compareTo(canonical(b));
    });
    records[key] = frontier.last;
  }

  void merge(Map<String, dynamic> envelope) {
    if (envelope['schema'] != 2 || envelope['records'] is! Map) {
      throw const FormatException('Unsupported sync snapshot');
    }
    final rawRecovery = envelope['recovery'];
    if (rawRecovery is Map) {
      for (final entry in rawRecovery.entries) {
        if (entry.value is Map) {
          recovery[entry.key.toString()] =
              Map<String, dynamic>.from(entry.value);
          final archivedClock = (entry.value['clock'] as num?)?.toInt() ?? 0;
          if (archivedClock > clock) clock = archivedClock;
        }
      }
    }
    for (final entry in (envelope['records'] as Map).entries) {
      final incoming = Map<String, dynamic>.from(entry.value as Map);
      final stamp = (incoming['clock'] as num).toInt();
      if (stamp > clock) clock = stamp;
      final key = entry.key.toString();
      final local = records[key];
      if (key.startsWith('session/')) {
        if (local != null) _archive(key, local);
        _archive(key, incoming);
        continue;
      }
      // Legacy daily totals overlap between devices: merge maxima only at the
      // zero-clock baseline. New events have unique IDs and are added once.
      if (local != null &&
          stamp == 0 &&
          local['clock'] == 0 &&
          key.startsWith('dailyBase/')) {
        final counts = Map<String, dynamic>.from(local['value'] as Map? ?? {});
        for (final count in (incoming['value'] as Map? ?? {}).entries) {
          if ((count.value as num) > ((counts[count.key] as num?) ?? 0))
            counts[count.key.toString()] = count.value;
        }
        records[key] = {...local, 'value': counts};
        continue;
      }
      final order = local == null ? 1 : compare(incoming, local);
      if (local == null || order > 0) {
        records[key] = incoming;
      }
    }
    // An envelope may carry a previously hidden branch in recovery only.
    final sessionKeys = <String>{
      ...records.keys.where((key) => key.startsWith('session/')),
      for (final key in recovery.keys)
        if (key.startsWith('session/') && key.contains('@'))
          key.substring(0, key.lastIndexOf('@', key.lastIndexOf('@') - 1)),
    };
    for (final key in sessionKeys) {
      _resolveSession(key);
    }
  }

  Map<String, dynamic> get values => {
        for (final entry in records.entries) entry.key: entry.value['value'],
      };

  Map<String, dynamic> toJson() => {
        'schema': 2,
        'deviceId': deviceId,
        'clock': clock,
        'records': records,
        'recovery': recovery,
      };
}
