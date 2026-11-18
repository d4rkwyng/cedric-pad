// The built-in engine's llama.cpp calls, as function pointers resolved
// with dlopen/dlsym the first time a model is loaded, instead of linking
// llama.framework into the app: linked, dyld loads and binds it (with
// Metal and Accelerate) on every launch, ~2-3 ms warm, for an engine that
// is off by default. Each pointer has the exact type of the function in
// llama.h (__typeof__ doesn't reference the symbol), so a changed
// signature fails to compile here.
#pragma once
#include <stddef.h>
#include <llama/llama.h>

#define CEDRIC_LLAMA_FN(name) __typeof__(&name) name

typedef struct cedric_llama_api {
    CEDRIC_LLAMA_FN(llama_log_set);
    CEDRIC_LLAMA_FN(llama_backend_init);
    CEDRIC_LLAMA_FN(llama_model_default_params);
    CEDRIC_LLAMA_FN(llama_model_load_from_file);
    CEDRIC_LLAMA_FN(llama_context_default_params);
    CEDRIC_LLAMA_FN(llama_init_from_model);
    CEDRIC_LLAMA_FN(llama_model_free);
    CEDRIC_LLAMA_FN(llama_model_get_vocab);
    CEDRIC_LLAMA_FN(llama_model_chat_template);
    CEDRIC_LLAMA_FN(llama_free);
    CEDRIC_LLAMA_FN(llama_memory_clear);
    CEDRIC_LLAMA_FN(llama_get_memory);
    CEDRIC_LLAMA_FN(llama_decode);
    CEDRIC_LLAMA_FN(llama_batch_get_one);
    CEDRIC_LLAMA_FN(llama_sampler_sample);
    CEDRIC_LLAMA_FN(llama_sampler_free);
    CEDRIC_LLAMA_FN(llama_sampler_chain_init);
    CEDRIC_LLAMA_FN(llama_sampler_chain_default_params);
    CEDRIC_LLAMA_FN(llama_sampler_chain_add);
    CEDRIC_LLAMA_FN(llama_sampler_init_grammar);
    CEDRIC_LLAMA_FN(llama_sampler_init_greedy);
    CEDRIC_LLAMA_FN(llama_vocab_is_eog);
    CEDRIC_LLAMA_FN(llama_token_to_piece);
    CEDRIC_LLAMA_FN(llama_tokenize);
    CEDRIC_LLAMA_FN(llama_chat_apply_template);
} cedric_llama_api;

/// Loads llama.framework (already loaded: reused) and resolves every
/// function; NULL on failure, with a reason in `error`. Thread-safe; the
/// first successful result is cached.
const cedric_llama_api *cedric_llama_load(char *error, size_t error_len);
