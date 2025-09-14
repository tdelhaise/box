#include "BFVersion.h"
#include <jni.h>

JNIEXPORT jstring JNICALL Java_org_box_Native_boxVersion(JNIEnv *environment, jclass classRef) {
    (void)classRef;
    const char *version = BFVersionString();
    return (*environment)->NewStringUTF(environment, version ? version : "");
}
