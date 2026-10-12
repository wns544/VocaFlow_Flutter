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
      records.putIfAbsent(entry.key, () => {
        'clock': 0, 'device': deviceId, 'value': entry.value,
      });
    }
    acceptView(values);
  }

  void acceptView(Map<String, dynamic> values) {
    _view = jsonDecode(jsonEncode(values)) as Map<String, dynamic>;
  }

  bool capture(Map<String, dynamic> values, {int? nowMicros}) {
    final changed = {..._view.keys, ...values.keys}.where(
      (key) => canonical(_view[key]) != canonical(values[key]),
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

  void merge(Map<String, dynamic> envelope) {
    if (envelope['schema'] != 2 || envelope['records'] is! Map) {
      throw const FormatException('Unsupported sync snapshot');
    }
    final rawRecovery = envelope['recovery'];
    if (rawRecovery is Map) {
      for (final entry in rawRecovery.entries) {
        if (entry.value is Map) {
          recovery[entry.key.toString()] = Map<String, dynamic>.from(entry.value);
        }
      }
    }
    for (final entry in (envelope['records'] as Map).entries) {
      final incoming = Map<String, dynamic>.from(entry.value as Map);
      final stamp = (incoming['clock'] as num).toInt();
      if (stamp > clock) clock = stamp;
      final key = entry.key.toString();
      final local = records[key];
      // Legacy daily totals overlap between devices: merge maxima only at the
      // zero-clock baseline. New events have unique IDs and are added once.
      if (local != null && stamp == 0 && local['clock'] == 0 && key.startsWith('dailyBase/')) {
        final counts = Map<String, dynamic>.from(local['value'] as Map? ?? {});
        for (final count in (incoming['value'] as Map? ?? {}).entries) {
          if ((count.value as num) > ((counts[count.key] as num?) ?? 0)) counts[count.key.toString()] = count.value;
        }
        records[key] = {...local, 'value': counts};
        continue;
      }
      if (local == null || compare(incoming, local) > 0) {
        if (local != null && key.startsWith('session/') &&
            canonical(local['value']) != canonical(incoming['value'])) {
          _archive(key, local);
        }
        records[key] = incoming;
      } else if (compare(incoming, local) < 0 && key.startsWith('session/') &&
          canonical(local['value']) != canonical(incoming['value'])) {
        _archive(key, incoming);
      }
    }
  }

  Map<String, dynamic> get values => {
    for (final entry in records.entries) entry.key: entry.value['value'],
  };

  Map<String, dynamic> toJson() => {
    'schema': 2, 'deviceId': deviceId, 'clock': clock,
    'records': records, 'recovery': recovery,
  };
}
