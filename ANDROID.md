Android Support (Client and Server)

Scope and Goals
- Client: Build Box core as an Android NDK library and expose a thin JNI layer so Android apps can call sendTo/getFrom/list/deleteFrom and connectivity checks.
- Server (boxd): Support two modes
  1) App-based foreground service (works but subject to Android background limits; good for hobby use).
  2) AOSP native daemon on devices you control (Android-on-Pi): reliable via init and SELinux policies.

What Works Today
- Minimal cross-build target (BoxCoreMinimal) compiles core data structures and protocol framing without OpenSSL/DTLS dependencies.
- This is a first step to validate NDK toolchains; full BoxFoundation (with OpenSSL) will be enabled later by providing Android-native OpenSSL/libsodium builds.

Build (NDK) — Minimal Core
Prereqs
- Android Studio or standalone Android NDK r26+.
- CMake 3.22+ (bundled with NDK or external).

Example (arm64-v8a)
  export ANDROID_NDK=$HOME/Android/Sdk/ndk/26.1.10909125
  cmake -S . -B build-android-arm64 \
    -D CMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -D ANDROID_ABI=arm64-v8a \
    -D ANDROID_PLATFORM=android-24 \
    -D BOX_BUILD_MINIMAL=ON \
    -D CMAKE_BUILD_TYPE=Release
  cmake --build build-android-arm64 -j

Artifacts
- Static or shared lib `libBoxCoreMinimal` suitable for packaging in an AAR via JNI.

JNI Wrapper (android/jni)
- A minimal JNI wrapper is provided under `android/jni` that links to `BoxCoreMinimal` and exposes:
  - `org.box.Native.boxVersion()` → returns version string from the C core.
- Build JNI wrapper:
  export ANDROID_NDK=$HOME/Android/Sdk/ndk/26.1.10909125
  cmake -S android/jni -B build-android-jni \
    -D CMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -D ANDROID_ABI=arm64-v8a \
    -D ANDROID_PLATFORM=android-24 \
    -D BOX_BUILD_MINIMAL=ON \
    -D CMAKE_BUILD_TYPE=Release
  cmake --build build-android-jni -j

JNI Wrapper (Sketch)
- Create an Android module that loads `libBoxCoreMinimal` and wraps C APIs with JNI methods.
- Example class method:
  public native String boxVersion(); // calls a small C function returning version

Permissions for Client App
- Required: `INTERNET`.
- Recommended: `WAKE_LOCK`, `ACCESS_NETWORK_STATE`.
- For NAT/UPnP discovery over Wi‑Fi: `CHANGE_WIFI_MULTICAST_STATE` and acquire a `WifiManager.MulticastLock` during discovery.

Server on Stock Android (Foreground Service)
- Foreground service + ongoing notification to avoid background kills.
- Ask user to exclude from battery optimizations (ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).
- Keep Wi‑Fi on during sleep (device setting or `WifiManager` high‑perf lock); consider Ethernet when available.
- Caveat: CPE/NAT/Firewall may still block inbound unless configured; IPv6 with allowed UDP rule is the recommended path.

Server on AOSP (Android-on-Pi)
- Install native `boxd` and shared libs in the system image (`/system` or `/system_ext`).
- Create an init rc service:
  service boxd /system/bin/boxd --config /data/box/boxd.toml
    class main
    user boxd
    group inet
    oneshot
    disabled
    seclabel u:object_r:boxd_exec:s0

- SELinux policy (snippet; device policy add-on):
  type boxd, domain, coredomain;
  type boxd_exec, exec_type, file_type;
  init_daemon_domain(boxd)
  allow boxd self:udp_socket { create connect sendto recvfrom bind getopt setopt };
  allow boxd system_file:file { read open execute };  # adjust depending on placement
  allow boxd boxd_data_file:dir { create add_name remove_name write search read open };
  allow boxd boxd_data_file:file { create write read open append getattr };

- Filesystem layout:
  - `/data/box` (700) owned by `boxd:boxd` for data and configs (mirrors `~/.box`).
  - Admin channel: `/data/box/run/boxd.sock` (600) same-user only.

Networking Notes
- IPv6: preferred; ensure CPE firewall rule allows inbound UDP `<port>` to device IPv6.
- IPv4: NAT typical; PCP/NAT‑PMP/UPnP discovery requires Wi‑Fi multicast permissions and locks.

Planned (Future)
- Build full `BoxFoundation` on Android by integrating OpenSSL (or BoringSSL) and libsodium builds for ABIs.
- JNI for core operations (sendTo/getFrom/etc.) and the connectivity diagnostic.
- A sample Android client app module.

CI (Build-Only, Minimal)
- Workflow includes a job that sets up the Android NDK and compiles `BoxCoreMinimal` for `arm64-v8a` to validate cross-builds.
 - The job also builds the JNI wrapper (`boxjni`) to validate linking.

Try Locally (Device/Emulator)

Prereqs
- An Android device or emulator with Developer Options enabled and `adb` available.
- Android Studio (recommended) or command-line Gradle, plus the NDK if you plan to build natively.

Option A — Android Studio sample app
1) Create a new Android app (e.g., package `org.box.sample`).
2) Either:
   - Add externalNativeBuild to point to `android/jni/CMakeLists.txt` (preferred), or
   - Copy the built `libboxjni.so` into `app/src/main/jniLibs/<abi>/` (e.g., `arm64-v8a`).
3) Add a Java/Kotlin bridge class matching the JNI signature:
   - Java:
     package org.box;
     public final class Native {
       static { System.loadLibrary("boxjni"); }
       public static native String boxVersion();
     }
4) Call the native method from your Activity and log/Toast the result:
   - `Log.i("Box", "version=" + org.box.Native.boxVersion());`
5) Install and run on the device. You should see the version string (e.g., `0.1.0`).

Option B — Command-line verification
- Build the JNI library as above, then verify on host that the exported symbol exists:
  - `nm -D build-android-jni/libboxjni.so | grep Java_org_box_Native_boxVersion`
- To load on device, you will still need an Android app process; JNI cannot run standalone from shell without a Java VM process. Use Option A for a true runtime check.

Notes
- Ensure your app includes `android:extractNativeLibs=true` in the manifest if targeting API levels where Play’s native lib extraction behavior changes.
- For multi-ABI support, build and package `arm64-v8a` and (optionally) `armeabi-v7a` and `x86_64` variants of `libboxjni.so`.
