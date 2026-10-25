/// Native payloads that can grow with the user's study history. Keeping any
/// of these in SharedPreferences makes unrelated small settings rewrite the
/// entire XML file.
bool isLargeLocalValueKey(String key) =>
    key == 'books' ||
    key == 'sync.v2.replica' ||
    key == 'cardChangeTracker.v1' ||
    key == 'cloudChangeTracker.v1' ||
    key.startsWith('accountState.v1.') ||
    key.startsWith('sync.v2.checkpoint.') ||
    key.startsWith('sync.v2.beforeMigration.') ||
    key.startsWith('sync.v2.imported.') ||
    key.startsWith('learning.pendingWordStates.') ||
    key.startsWith('cardChangeTracker.v1.') ||
    key.startsWith('cloudChangeTracker.v2.');
