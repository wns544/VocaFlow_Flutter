/// Read-only, field-level planning for a future reference/PDF update.
/// This deliberately exposes NO apply/upload method. A plan is not a receipt.
const referenceTextFields = {
  'term',
  'reading',
  'meaning',
  'example',
  'exampleMeaning',
  'explanation'
};

String _identity(Map<String, dynamic> card) {
  if (card['bookId'] is! String ||
      (card['bookId'] as String).isEmpty ||
      card['wordId'] is! int) {
    throw const FormatException('Stable bookId and integer wordId required');
  }
  return '${card['bookId']}/${card['wordId']}';
}

Map<String, Map<String, dynamic>> _index(List<Map<String, dynamic>> cards) {
  final result = <String, Map<String, dynamic>>{};
  for (final card in cards) {
    final id = _identity(card);
    if (result.containsKey(id)) {
      throw FormatException('Duplicate identity: $id');
    }
    result[id] = card;
  }
  return result;
}

Map<String, dynamic> planReferenceCorrections({
  required List<Map<String, dynamic>> baseline,
  required List<Map<String, dynamic>> current,
  required List<Map<String, dynamic>> proposed,
}) {
  final bases = _index(baseline),
      live = _index(current),
      next = _index(proposed);
  final eligible = <Map<String, dynamic>>[], held = <Map<String, dynamic>>[];
  for (final entry in next.entries) {
    final original = bases[entry.key], server = live[entry.key];
    final changes = entry.value['fields'];
    if (changes is! Map) throw const FormatException('fields map required');
    for (final field in changes.entries) {
      if (!referenceTextFields.contains(field.key) || field.value is! String) {
        throw FormatException('Unsupported reference field: ${field.key}');
      }
      final oldFields = original?['fields'] as Map? ?? const {};
      if (oldFields.containsKey(field.key) &&
          oldFields[field.key] == field.value) {
        continue;
      }
      final currentFields = server?['fields'] as Map? ?? const {};
      final versions = server?['fieldRevisions'] as Map? ?? const {};
      final baseVersions = original?['fieldRevisions'] as Map? ?? const {};
      final owned = original?['referenceOwnedFields'] as List? ?? const [];
      final protected = {
        ...?original?['protectedFields'] as List?,
        ...?server?['protectedFields'] as List?,
      };
      String? reason;
      if (original == null || server == null) {
        reason = 'missing-baseline-or-current';
      } else if (original['deleted'] == true || server['deleted'] == true) {
        reason = 'deleted-card';
      } else if (protected.contains(field.key)) {
        reason = 'protected-custom-field';
      } else if (!owned.contains(field.key)) {
        // Imported custom meanings can have revision0. Equal values and a
        // zero revision alone are NOT evidence of reference ownership.
        reason = 'unknown-provenance';
      } else if (!oldFields.containsKey(field.key) ||
          !currentFields.containsKey(field.key)) {
        reason = 'missing-field';
      } else if (currentFields[field.key] != oldFields[field.key]) {
        reason = 'current-value-diverged';
      } else if (versions[field.key] is! int ||
          baseVersions[field.key] is! int) {
        reason = 'missing-field-revision';
      } else if (versions[field.key] != 0 ||
          versions[field.key] != baseVersions[field.key]) {
        reason = 'previously-edited-field';
      }
      final row = <String, dynamic>{
        'bookId': entry.value['bookId'],
        'wordId': entry.value['wordId'],
        'field': field.key,
        'before': currentFields[field.key],
        'after': field.value,
        'expectedFieldRevision': versions[field.key],
        if (reason != null) 'reason': reason,
      };
      (reason == null ? eligible : held).add(row);
    }
  }
  return {
    'schema': 1,
    'mode': 'read-only-plan',
    'firestoreWrites': 0,
    'createsOrDeletes': 0,
    'eligible': eligible,
    'held': held,
    'notice':
        'Eligibility is not permission to apply. Re-read and compare value/revision in the eventual server transaction.',
  };
}
