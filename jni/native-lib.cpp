#include <jni.h>
#include <android/log.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <unistd.h>

#include <algorithm>
#include <ctime>
#include <mutex>
#include <string>
#include <vector>

#include "llama.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "BYOM_Engine", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "BYOM_Engine", __VA_ARGS__)

static std::mutex g_engine_mutex;
static std::mutex g_log_mutex;
static struct llama_model * g_model = nullptr;
static struct llama_context * g_ctx = nullptr;
static FILE * g_model_file = nullptr;
static bool g_backend_ready = false;
static std::string g_last_llama_log;

static std::string trim_copy(const std::string & text) {
    const size_t start = text.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }

    const size_t end = text.find_last_not_of(" \t\r\n");
    return text.substr(start, end - start + 1);
}

static void clear_last_llama_log() {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_last_llama_log.clear();
}

static std::string get_last_llama_log() {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    return trim_copy(g_last_llama_log);
}

static void remember_llama_log(enum ggml_log_level level, const char * text) {
    if (text == nullptr || text[0] == '\0') {
        return;
    }

    std::lock_guard<std::mutex> lock(g_log_mutex);
    if (level == GGML_LOG_LEVEL_CONT) {
        if (!g_last_llama_log.empty()) {
            g_last_llama_log += text;
        }
        return;
    }

    if (level >= GGML_LOG_LEVEL_WARN) {
        g_last_llama_log = text;
    }
}

static void llama_android_log_callback(enum ggml_log_level level, const char * text, void * user_data) {
    (void) user_data;

    if (text == nullptr) {
        return;
    }

    int android_level = ANDROID_LOG_INFO;
    switch (level) {
        case GGML_LOG_LEVEL_ERROR:
            android_level = ANDROID_LOG_ERROR;
            break;
        case GGML_LOG_LEVEL_WARN:
            android_level = ANDROID_LOG_WARN;
            break;
        case GGML_LOG_LEVEL_DEBUG:
            android_level = ANDROID_LOG_DEBUG;
            break;
        case GGML_LOG_LEVEL_INFO:
        case GGML_LOG_LEVEL_CONT:
        case GGML_LOG_LEVEL_NONE:
        default:
            android_level = ANDROID_LOG_INFO;
            break;
    }

    __android_log_write(android_level, "BYOM_Llama", text);
    remember_llama_log(level, text);
}

static void reset_engine() {
    if (g_ctx != nullptr) {
        llama_free(g_ctx);
        g_ctx = nullptr;
    }

    if (g_model != nullptr) {
        llama_model_free(g_model);
        g_model = nullptr;
    }

    if (g_model_file != nullptr) {
        fclose(g_model_file);
        g_model_file = nullptr;
    }
}

static jstring make_java_string(JNIEnv * env, const std::string & text) {
    return env->NewStringUTF(text.c_str());
}

static std::string token_to_piece(const struct llama_vocab * vocab, llama_token token) {
    std::vector<char> buffer(128);
    int written = llama_token_to_piece(vocab, token, buffer.data(), static_cast<int32_t>(buffer.size()), 0, true);

    if (written < 0) {
        buffer.resize(-written);
        written = llama_token_to_piece(vocab, token, buffer.data(), static_cast<int32_t>(buffer.size()), 0, true);
    }

    if (written < 0) {
        return "";
    }

    return std::string(buffer.data(), written);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_amiraq_byom_MainActivity_loadModelFromFd(JNIEnv * env, jobject /* this */, jint fd) {
    std::lock_guard<std::mutex> lock(g_engine_mutex);

    reset_engine();
    clear_last_llama_log();

    const int native_fd = dup(fd);
    if (native_fd < 0) {
        LOGE("Failed to duplicate incoming file descriptor.");
        return make_java_string(env, "ERROR: Failed to duplicate model file descriptor.");
    }

    FILE * model_file = fdopen(native_fd, "rb");
    if (model_file == nullptr) {
        const std::string reason = std::strerror(errno);
        close(native_fd);
        return make_java_string(env, "ERROR: Failed to open duplicated model descriptor: " + reason);
    }

    if (!g_backend_ready) {
        llama_log_set(llama_android_log_callback, nullptr);
        ggml_backend_load_all();
        llama_backend_init();
        g_backend_ready = true;
    }

    LOGI("Loading GGUF model from duplicated file descriptor %d", native_fd);

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;
    model_params.split_mode = LLAMA_SPLIT_MODE_NONE;
    model_params.main_gpu = -1;
    model_params.use_mmap = false;
    model_params.use_mlock = false;

    g_model = llama_model_load_from_file_ptr(model_file, model_params);
    if (g_model == nullptr) {
        const std::string detail = get_last_llama_log();
        fclose(model_file);

        std::string error = "ERROR: Failed to load GGUF model.";
        if (!detail.empty()) {
            error += "\n" + detail;
        }

        LOGE("%s", error.c_str());
        return make_java_string(env, error);
    }

    g_model_file = model_file;
    clear_last_llama_log();

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = 1024;
    ctx_params.n_batch = 128;
    ctx_params.n_ubatch = 128;
    ctx_params.n_threads = 4;
    ctx_params.n_threads_batch = 4;
    ctx_params.no_perf = true;

    g_ctx = llama_init_from_model(g_model, ctx_params);
    if (g_ctx == nullptr) {
        const std::string detail = get_last_llama_log();
        std::string error = "ERROR: Failed to create inference context.";
        if (!detail.empty()) {
            error += "\n" + detail;
        }

        LOGE("%s", error.c_str());
        reset_engine();
        return make_java_string(env, error);
    }

    LOGI("Model loaded and ready for inference.");
    return nullptr;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_amiraq_byom_MainActivity_generateText(JNIEnv * env, jobject /* this */, jstring prompt_j, jint max_tokens) {
    const char * prompt_chars = env->GetStringUTFChars(prompt_j, nullptr);
    if (prompt_chars == nullptr) {
        return make_java_string(env, "[ERROR] Failed to read prompt text.");
    }

    const std::string prompt(prompt_chars);
    env->ReleaseStringUTFChars(prompt_j, prompt_chars);

    if (prompt.empty()) {
        return make_java_string(env, "[ERROR] Enter a prompt first.");
    }

    std::lock_guard<std::mutex> lock(g_engine_mutex);

    if (g_model == nullptr || g_ctx == nullptr) {
        return make_java_string(env, "[ERROR] Load a GGUF model before generating text.");
    }

    const struct llama_vocab * vocab = llama_model_get_vocab(g_model);
    if (vocab == nullptr) {
        return make_java_string(env, "[ERROR] Model vocabulary is unavailable.");
    }

    llama_memory_clear(llama_get_memory(g_ctx), true);

    const int prompt_token_count = -llama_tokenize(
            vocab,
            prompt.c_str(),
            static_cast<int32_t>(prompt.size()),
            nullptr,
            0,
            true,
            true);

    if (prompt_token_count <= 0) {
        return make_java_string(env, "[ERROR] Failed to tokenize the prompt.");
    }

    std::vector<llama_token> prompt_tokens(prompt_token_count);
    if (llama_tokenize(
            vocab,
            prompt.c_str(),
            static_cast<int32_t>(prompt.size()),
            prompt_tokens.data(),
            static_cast<int32_t>(prompt_tokens.size()),
            true,
            true) < 0) {
        return make_java_string(env, "[ERROR] Failed to tokenize the prompt.");
    }

    const int context_window = static_cast<int>(llama_n_ctx(g_ctx));
    const int available_tokens = context_window - static_cast<int>(prompt_tokens.size()) - 1;

    if (available_tokens <= 0) {
        return make_java_string(env, "[ERROR] Prompt is longer than the available context window.");
    }

    const int predict_tokens = std::min(std::max(1, static_cast<int>(max_tokens)), available_tokens);

    llama_sampler_chain_params sampler_params = llama_sampler_chain_default_params();
    sampler_params.no_perf = true;
    struct llama_sampler * sampler = llama_sampler_chain_init(sampler_params);
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.8f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(static_cast<uint32_t>(time(nullptr))));

    llama_batch batch = llama_batch_get_one(prompt_tokens.data(), static_cast<int32_t>(prompt_tokens.size()));

    if (llama_model_has_encoder(g_model)) {
        if (llama_encode(g_ctx, batch) != 0) {
            llama_sampler_free(sampler);
            return make_java_string(env, "[ERROR] Failed to encode prompt.");
        }

        llama_token decoder_start = llama_model_decoder_start_token(g_model);
        if (decoder_start == LLAMA_TOKEN_NULL) {
            decoder_start = llama_vocab_bos(vocab);
        }

        batch = llama_batch_get_one(&decoder_start, 1);
    }

    std::string generated_text;
    const int total_tokens = static_cast<int>(prompt_tokens.size()) + predict_tokens;

    for (int n_pos = 0; n_pos + batch.n_tokens < total_tokens; ) {
        if (llama_decode(g_ctx, batch) != 0) {
            llama_sampler_free(sampler);
            return make_java_string(env, "[ERROR] llama_decode failed while generating text.");
        }

        n_pos += batch.n_tokens;

        const llama_token next_token = llama_sampler_sample(sampler, g_ctx, -1);
        if (llama_vocab_is_eog(vocab, next_token)) {
            break;
        }

        generated_text += token_to_piece(vocab, next_token);
        llama_token next_token_copy = next_token;
        batch = llama_batch_get_one(&next_token_copy, 1);
    }

    llama_sampler_free(sampler);

    if (generated_text.empty()) {
        return make_java_string(env, "[ERROR] Model returned no visible output.");
    }

    LOGI("Generated %zu bytes of text.", generated_text.size());
    return make_java_string(env, generated_text);
}
