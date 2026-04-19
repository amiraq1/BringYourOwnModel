#include <jni.h>
#include <android/log.h>
#include <unistd.h>
#include <string>
#include "llama.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "BYOM_Engine", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "BYOM_Engine", __VA_ARGS__)

// الاحتفاظ بحالة المحرك
struct llama_model *model = nullptr;
struct llama_context *ctx = nullptr;

extern "C" JNIEXPORT void JNICALL
Java_com_amiraq_byom_MainActivity_loadModelFromFd(JNIEnv *env, jobject /* this */, jint fd) {
    LOGI("SYSTEM INTERRUPT: JNI Bridge received FD: %d", fd);

    // 1. استنساخ المعرف لضمان استقراره
    int native_fd = dup(fd);
    if (native_fd < 0) {
        LOGE("FATAL: Failed to duplicate File Descriptor.");
        return;
    }

    // 2. إيقاظ المحرك (الواجهة الحديثة لا تتطلب تمرير معاملات)
    llama_backend_init();
    LOGI("Llama backend initialized.");

    // 3. بناء المسار الوهمي (The Magic Bridge)
    // هذا المسار سيسمح لـ llama.cpp بفتح الملف وكأنه مسار عادي
    std::string virtual_path = "/proc/self/fd/" + std::to_string(native_fd);
    LOGI("Virtual path constructed: %s", virtual_path.c_str());

    // 4. تحميل النموذج باستخدام الدالة الرسمية
    llama_model_params model_params = llama_model_default_params();
    model = llama_load_model_from_file(virtual_path.c_str(), model_params);

    if (model == nullptr) {
        LOGE("FATAL: Engine failed to map model from %s.", virtual_path.c_str());
        close(native_fd); // تحرير الذاكرة في حالة الفشل
        return;
    }

    LOGI("SUCCESS: Model loaded into memory mapping via virtual FS.");

    // 5. تهيئة سياق الاستدلال
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = 1024; // سياق محدود لضمان عدم تجاوز RAM
    ctx_params.n_threads = 4; // يتناسب مع أنوية الأداء في هواتف ARM

    ctx = llama_new_context_with_model(model, ctx_params);
    if (ctx == nullptr) {
        LOGE("FATAL: Failed to create inference context.");
        return;
    }

    LOGI("SYSTEM READY: Inference context active.");
}
