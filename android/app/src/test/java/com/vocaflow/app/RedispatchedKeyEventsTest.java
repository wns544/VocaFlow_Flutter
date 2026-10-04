package com.vocaflow.app;

// Standalone JVM regression test; no Android device or extra dependency needed.
public final class RedispatchedKeyEventsTest {
    public static void main(String[] args) {
        RedispatchedKeyEvents events = new RedispatchedKeyEvents();
        Object down = new Object();
        Object up = new Object();
        check(!events.isRedispatch(down), "initial DOWN must be debounced");
        events.remember(down);
        check(!events.isRedispatch(new Object()), "distinct duplicate must not bypass debounce");
        check(events.isRedispatch(down), "Flutter DOWN redispatch must pass through");
        check(!events.isRedispatch(down), "redispatch reservation must be consumed");
        events.remember(up);
        check(events.isRedispatch(up), "Flutter UP redispatch must pass through");
        events.remember(down);
        events.remember(up);
        check(events.isRedispatch(up), "out-of-order async UP must be recognized");
        check(events.isRedispatch(down), "out-of-order async DOWN must be recognized");
        System.out.println("RedispatchedKeyEvents: 8 assertions passed");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
