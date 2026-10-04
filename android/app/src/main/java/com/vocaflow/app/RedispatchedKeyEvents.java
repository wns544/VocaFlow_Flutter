package com.vocaflow.app;

import java.util.WeakHashMap;

/** Tracks event identity without keeping Android KeyEvents alive. */
final class RedispatchedKeyEvents {
    private final WeakHashMap<Object, Boolean> forwarded = new WeakHashMap<>();

    // Android KeyEvent uses Object identity equality. Flutter redispatches the
    // original object, so a separate event must still pass through debouncing.
    boolean isRedispatch(Object event) {
        return forwarded.remove(event) != null;
    }

    void remember(Object event) {
        forwarded.put(event, Boolean.TRUE);
    }
}
