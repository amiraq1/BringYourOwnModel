#include <jni.h>
#include <android/log.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "BYOM_Engine", __VA_ARGS__)

extern "C" JNIEXPORT void JNICALL
Java_com_amiraq_byom_MainActivity_loadModelFromFd(JNIEnv* env, jobject /* this */, jint fd) {
    (void)env;
    LOGI("SYSTEM INTERRUPT: Native Bridge Activated.");
    LOGI("Received File Descriptor: %d. Ready for GGUF parsing.", fd);
}
