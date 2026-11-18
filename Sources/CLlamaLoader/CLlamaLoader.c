#include "CLlamaLoader.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static cedric_llama_api api;
static const cedric_llama_api *loaded;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

// The app's rpath (@executable_path/../Frameworks) finds it in
// Cedric.app/Contents/Frameworks; a test bundle that links it already has
// it loaded under this install name.
static const char *const paths[] = {
    "@rpath/llama.framework/Versions/Current/llama",
    "@rpath/llama.framework/llama",
};

const cedric_llama_api *cedric_llama_load(char *error, size_t error_len) {
    pthread_mutex_lock(&lock);
    if (loaded) { pthread_mutex_unlock(&lock); return loaded; }
    void *h = NULL;
    for (size_t i = 0; i < sizeof paths / sizeof *paths && !h; i++) h = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        if (error && error_len) snprintf(error, error_len, "llama.framework could not be loaded: %s", dlerror());
        pthread_mutex_unlock(&lock);
        return NULL;
    }
    int ok = 1;
#define RESOLVE(name) do { \
        api.name = (__typeof__(api.name))dlsym(h, #name); \
        if (!api.name && ok) { ok = 0; if (error && error_len) snprintf(error, error_len, "llama.framework has no %s", #name); } \
    } while (0)
    RESOLVE(llama_log_set);
    RESOLVE(llama_backend_init);
    RESOLVE(llama_model_default_params);
    RESOLVE(llama_model_load_from_file);
    RESOLVE(llama_context_default_params);
    RESOLVE(llama_init_from_model);
    RESOLVE(llama_model_free);
    RESOLVE(llama_model_get_vocab);
    RESOLVE(llama_model_chat_template);
    RESOLVE(llama_free);
    RESOLVE(llama_memory_clear);
    RESOLVE(llama_get_memory);
    RESOLVE(llama_decode);
    RESOLVE(llama_batch_get_one);
    RESOLVE(llama_sampler_sample);
    RESOLVE(llama_sampler_free);
    RESOLVE(llama_sampler_chain_init);
    RESOLVE(llama_sampler_chain_default_params);
    RESOLVE(llama_sampler_chain_add);
    RESOLVE(llama_sampler_init_grammar);
    RESOLVE(llama_sampler_init_greedy);
    RESOLVE(llama_vocab_is_eog);
    RESOLVE(llama_token_to_piece);
    RESOLVE(llama_tokenize);
    RESOLVE(llama_chat_apply_template);
#undef RESOLVE
    if (ok) loaded = &api;
    pthread_mutex_unlock(&lock);
    return loaded;
}
