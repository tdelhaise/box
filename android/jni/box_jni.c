#include "box/BFVersion.h"
#include <jni.h>

JNIEXPORT jstring JNICALL Java_org_box_Native_boxVersion(JNIEnv *env, jclass clazz) {
    (void)clazz;
    const char *ver = BFVersionString();
    return (*env)->NewStringUTF(env, ver ? ver : "");
}
