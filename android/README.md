Android JNI Wrapper Module

This directory contains a minimal JNI bridge that exposes Box core version info to Android apps. It links against the minimal C core (BoxCoreMinimal) built for Android.

Build (standalone)
- Prereqs: Android NDK r26+, CMake 3.16+.
- Example:
  export ANDROID_NDK=$HOME/Android/Sdk/ndk/26.1.10909125
  cmake -S android/jni -B build-android-jni \
    -D CMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -D ANDROID_ABI=arm64-v8a \
    -D ANDROID_PLATFORM=android-24 \
    -D BOX_BUILD_MINIMAL=ON \
    -D CMAKE_BUILD_TYPE=Release
  cmake --build build-android-jni -j

Integration (Android Studio)
- Create an Android module (or use app module) and enable externalNativeBuild with CMake.
- Point the CMake script to `android/jni/CMakeLists.txt` and set the same toolchain/ABI/Platform.
- Define a Java/Kotlin class with the matching signature:
  package org.box;
  public final class Native {
    static { System.loadLibrary("boxjni"); }
    public static native String boxVersion();
  }

Notes
- This is a minimal bridge. Additional JNI methods can be added to call sendTo/getFrom/list/deleteFrom once those are exposed via the C API in BoxCoreMinimal/BoxFoundation-android.

