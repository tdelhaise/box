package org.box;

public final class Native {
    static {
        System.loadLibrary("boxjni");
    }

    public static native String boxVersion();
}

