import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/auto_backup.dart';

void main() {
  bool skip({
    String? accountId = 's23u-account',
    String? mergedAccountId = 's23u-account',
    Map<String, String>? mergedRevisions = const {
      's23u': 'revision-a',
      'a52s': 'revision-b',
    },
    Map<String, String>? serverRevisions = const {
      'a52s': 'revision-b',
      's23u': 'revision-a',
    },
    int? mergedGeneration = 7,
    int localGeneration = 7,
    bool localDirty = false,
    bool forceFull = false,
  }) =>
      canSkipLearningMerge(
        accountId: accountId,
        mergedAccountId: mergedAccountId,
        mergedRevisions: mergedRevisions,
        serverRevisions: serverRevisions,
        mergedGeneration: mergedGeneration,
        localGeneration: localGeneration,
        localDirty: localDirty,
        forceFull: forceFull,
      );

  test('only identical authoritative heads and clean local state may skip', () {
    expect(skip(), isTrue);
    expect(skip(serverRevisions: null), isFalse);
    expect(skip(mergedRevisions: null), isFalse);
    expect(skip(mergedRevisions: const {}), isFalse);
    expect(skip(localDirty: true), isFalse);
    expect(skip(localGeneration: 8), isFalse);
    expect(skip(forceFull: true), isFalse);
  });

  test('new device, changed revision and account switch require full merge',
      () {
    expect(skip(accountId: 'another-account'), isFalse);
    expect(skip(accountId: null), isFalse);
    expect(skip(serverRevisions: const {'s23u': 'revision-a'}), isFalse);
    expect(
        skip(serverRevisions: const {
          's23u': 'revision-a',
          'a52s': 'revision-c',
        }),
        isFalse);
    expect(
        skip(serverRevisions: const {
          's23u': 'revision-a',
          'a52s': 'revision-b',
          'web': 'revision-d',
        }),
        isFalse);
  });

  test('successful upload advances only this device head in clean merge cache',
      () {
    final revisions = learningRevisionsAfterUpload(
      accountId: 'account',
      mergedAccountId: 'account',
      mergedRevisions: const {'s23u': 'old', 'a52s': 'other'},
      deviceId: 's23u',
      uploadedRevision: 'new',
      uploadedGeneration: 8,
      localGeneration: 8,
      localDirty: false,
    );
    expect(revisions, {'s23u': 'new', 'a52s': 'other'});
    expect(
        canSkipLearningMerge(
          accountId: 'account',
          mergedAccountId: 'account',
          mergedRevisions: revisions,
          serverRevisions: const {'s23u': 'new', 'a52s': 'other'},
          mergedGeneration: 8,
          localGeneration: 8,
          localDirty: false,
          forceFull: false,
        ),
        isTrue);
    expect(
        canSkipLearningMerge(
          accountId: 'account',
          mergedAccountId: 'account',
          mergedRevisions: revisions,
          serverRevisions: const {'s23u': 'new', 'a52s': 'new-other'},
          mergedGeneration: 8,
          localGeneration: 8,
          localDirty: false,
          forceFull: false,
        ),
        isFalse);
  });

  test('upload cache cannot advance over a pending edit or account change', () {
    Map<String, String>? update({
      String? mergedAccountId = 'account',
      int localGeneration = 8,
      bool localDirty = false,
    }) =>
        learningRevisionsAfterUpload(
          accountId: 'account',
          mergedAccountId: mergedAccountId,
          mergedRevisions: const {'s23u': 'old'},
          deviceId: 's23u',
          uploadedRevision: 'new',
          uploadedGeneration: 8,
          localGeneration: localGeneration,
          localDirty: localDirty,
        );
    expect(update(localDirty: true), isNull);
    expect(update(localGeneration: 9), isNull);
    expect(update(mergedAccountId: 'other'), isNull);
  });

  test('legacy relation import stops after durable V2 learning upload', () {
    expect(
        shouldImportLegacyRelations(
          legacySyncImported: false,
          hasUploadedLearningState: false,
        ),
        isTrue);
    expect(
        shouldImportLegacyRelations(
          legacySyncImported: false,
          hasUploadedLearningState: true,
        ),
        isFalse);
    expect(
        shouldImportLegacyRelations(
          legacySyncImported: true,
          hasUploadedLearningState: false,
        ),
        isFalse);
  });
}
