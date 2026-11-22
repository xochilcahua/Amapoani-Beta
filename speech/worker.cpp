#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>
#include <unistd.h>
#include <whisper.h>
#include <sherpa-onnx/c-api/c-api.h>

namespace {
constexpr uint8_t default_reading_voice = 3;  // Kokoro v1.0 af_heart.

bool read_bytes(void *buffer, size_t size) {
    return std::fread(buffer, 1, size, stdin) == size;
}

void size_header(uint32_t size) {
    std::fwrite(&size, sizeof(size), 1, stdout);
}

void result(const void *bytes, uint32_t size) {
    size_header(size);
    if (size) std::fwrite(bytes, 1, size, stdout);
    std::fflush(stdout);
}

void quiet(ggml_log_level, const char *, void *) {}

int dictation(const char *path) {
    whisper_log_set(quiet, nullptr);
    auto context = std::unique_ptr<whisper_context, decltype(&whisper_free)>(
        whisper_init_from_file_with_params(path, whisper_context_default_params()), &whisper_free);
    if (!context) return 2;
    const bool multilingual = whisper_is_multilingual(context.get());
    result("ready", 5);
    uint32_t size;
    while (read_bytes(&size, sizeof(size))) {
        // Raw Float32 is the original English request. A language byte prefixes
        // newer requests, which makes their length one past a multiple of four.
        if (size > 240u * 1024 * 1024 + 1 || size % sizeof(float) > 1) return 3;
        const bool tagged = size % sizeof(float) == 1;
        uint8_t language = 1;  // English
        if (tagged) {
            if (!read_bytes(&language, 1) || language > 2) return 3;
            --size;
        }
        std::vector<float> audio(size / sizeof(float));
        if (!read_bytes(audio.data(), size)) return 3;
        if (language == 2 && !multilingual) {
            const uint8_t missing = 3;
            result(&missing, 1);
            continue;
        }
        double energy = 0;
        for (float sample : audio) energy += sample * sample;
        if (audio.empty() || energy / audio.size() < 0.000002) {
            const uint8_t no_speech = 0;
            result(&no_speech, tagged ? 1 : 0);
            continue;
        }
        auto options = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        options.language = language == 2 ? "es" : language == 0 && multilingual ? "auto" : "en";
        options.no_timestamps = true;
        options.no_context = true;
        options.n_threads = 4;
        options.print_progress = false;
        options.print_realtime = false;
        options.print_special = false;
        options.print_timestamps = false;
        std::string transcript;
        if (whisper_full(context.get(), options, audio.data(), static_cast<int>(audio.size())) != 0) return 4;
        if (tagged) {
            const char *detected = language == 0 && multilingual
                ? whisper_lang_str(whisper_full_lang_id(context.get())) : options.language;
            const char recognized = detected && std::strcmp(detected, "es") == 0 ? 2 :
                detected && std::strcmp(detected, "en") == 0 ? 1 : 0;
            transcript.push_back(recognized);
        }
        const auto count = whisper_full_n_segments(context.get());
        for (int segment = 0; segment < count; ++segment) {
            transcript += whisper_full_get_segment_text(context.get(), segment);
        }
        result(transcript.data(), static_cast<uint32_t>(transcript.size()));
    }
    return 0;
}

int reading(const char *path, const char *weights, const char *single_voice) {
    const auto folder = std::filesystem::path(path);
    const auto model = weights ? std::string(weights) :
        (folder / (std::filesystem::exists(folder / "model.onnx") ? "model.onnx" : "model.int8.onnx")).string();
    auto voices = (folder / "voices.bin").string();
    std::unique_ptr<FILE, decltype(&std::fclose)> voice_table(nullptr, &std::fclose);
    if (single_voice) {
        // The Kokoro v1 graph requires exactly 54 style slots. Populate slot zero
        // with the individual embedding. The remaining slots occupy sparse holes.
        constexpr size_t style_bytes = 510 * 256 * sizeof(float);
        std::unique_ptr<FILE, decltype(&std::fclose)> source(std::fopen(single_voice, "rb"), &std::fclose);
        std::vector<uint8_t> style(style_bytes);
        voice_table.reset(std::tmpfile());
        if (!source || !voice_table || std::fread(style.data(), 1, style.size(), source.get()) != style.size() ||
            std::fgetc(source.get()) != EOF || std::fwrite(style.data(), 1, style.size(), voice_table.get()) != style.size() ||
            std::fflush(voice_table.get()) || ftruncate(fileno(voice_table.get()), 54 * style_bytes)) return 2;
        std::rewind(voice_table.get());
        voices = "/dev/fd/" + std::to_string(fileno(voice_table.get()));
    }
    const auto tokens = (folder / "tokens.txt").string();
    const auto phonemes = (folder / "espeak-ng-data").string();
    SherpaOnnxOfflineTtsConfig config{};
    config.model.kokoro.model = model.c_str();
    config.model.kokoro.voices = voices.c_str();
    config.model.kokoro.tokens = tokens.c_str();
    config.model.kokoro.data_dir = phonemes.c_str();
    config.model.kokoro.lang = "en-us";
    config.model.kokoro.length_scale = 1.0f;
    config.model.num_threads = 2;
    config.model.provider = "cpu";
    config.max_num_sentences = 1;
    // Sherpa treats a per-request 0.2 as "use the configured scale".
    config.silence_scale = 0.2f;
    auto tts = std::unique_ptr<const SherpaOnnxOfflineTts, decltype(&SherpaOnnxDestroyOfflineTts)>(
        SherpaOnnxCreateOfflineTts(&config), &SherpaOnnxDestroyOfflineTts);
    if (!tts) return 2;
    voice_table.reset();
    SherpaOnnxGenerationConfig options{};
    options.sid = single_voice ? 0 : default_reading_voice;
    options.speed = 1.0f;
    options.silence_scale = 1.0f;
    const auto *warmup = SherpaOnnxOfflineTtsGenerateWithConfig(tts.get(), "Ready.", &options, nullptr, nullptr);
    if (!warmup || warmup->n <= 0) {
        if (warmup) SherpaOnnxDestroyOfflineTtsGeneratedAudio(warmup);
        return 2;
    }
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(warmup);
    const int32_t speakers = SherpaOnnxOfflineTtsNumSpeakers(tts.get());
    result("ready", 5);
    uint32_t size;
    while (read_bytes(&size, sizeof(size))) {
        if (size > 65536) return 3;
        std::string text(size, '\0');
        if (!read_bytes(text.data(), size)) return 3;
        int32_t speaker = default_reading_voice;
        bool paragraph = false;
        bool compressed = false;
        uint8_t speed = 100;
        size_t text_offset = 0;
        // Plain-text requests use the default. Tagged requests specify an English speaker and a paragraph flag.
        if (!text.empty() && text.front() == '\0') {
            if (text.size() <= 3) return 3;
            if (static_cast<uint8_t>(text[1]) == 255) {
                if (text.size() <= 5) return 3;
                speaker = static_cast<uint8_t>(text[2]);
                const auto flags = static_cast<uint8_t>(text[3]);
                speed = static_cast<uint8_t>(text[4]);
                if (flags > 3 || speed < 50 || speed > 200) return 3;
                paragraph = flags & 1;
                compressed = flags & 2;
                text_offset = 5;
            } else {
                speaker = static_cast<uint8_t>(text[1]);
                if (text[2] != 0 && text[2] != 1) return 3;
                paragraph = text[2] == 1;
                text_offset = 3;
            }
            if ((!single_voice && speaker >= speakers) || speaker > 29) return 3;
        }
        options.sid = single_voice ? 0 : speaker;
        options.speed = speed / 100.0f;
        options.silence_scale = compressed ? 0.2f : 1.0f;
        options.extra = speaker >= 28 ? R"({"lang":"es"})" : speaker >= 20 ? R"({"lang":"en"})" : nullptr;
        auto audio = std::unique_ptr<const SherpaOnnxGeneratedAudio, decltype(&SherpaOnnxDestroyOfflineTtsGeneratedAudio)>(
            SherpaOnnxOfflineTtsGenerateWithConfig(tts.get(), text.c_str() + text_offset, &options, nullptr, nullptr),
            &SherpaOnnxDestroyOfflineTtsGeneratedAudio);
        if (!audio || audio->n <= 0) {
            result(nullptr, 0);
            continue;
        }
        const uint32_t rate = audio->sample_rate;
        const uint32_t bytes = audio->n * sizeof(float);
        int32_t tail = 0;
        if (paragraph) {
            const int32_t minimum = audio->sample_rate * (compressed ? 180 : 430) / 1000;
            tail = minimum;
            for (int32_t i = audio->n - 1; i >= 0 && tail > 0 && std::abs(audio->samples[i]) < .012f; --i) {
                --tail;
            }
            tail = std::max(tail, audio->sample_rate * (compressed ? 100 : 280) / 1000);
        }
        size_header(bytes + sizeof(rate) + tail * sizeof(float));
        std::fwrite(&rate, sizeof(rate), 1, stdout);
        std::fwrite(audio->samples, 1, bytes, stdout);
        if (tail > 0) {
            const std::vector<float> quiet(tail, 0.0f);
            std::fwrite(quiet.data(), sizeof(float), quiet.size(), stdout);
        }
        std::fflush(stdout);
    }
    return 0;
}
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > 5) return 1;
    if (argc == 3 && std::strcmp(argv[1], "dictation") == 0) return dictation(argv[2]);
    if (std::strcmp(argv[1], "reading") == 0)
        return reading(argv[2], argc >= 4 ? argv[3] : nullptr, argc == 5 ? argv[4] : nullptr);
    return 1;
}
