#include "whisper.h"
#include <algorithm>
#include <chrono>
#include <fstream>
#include <iostream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;
std::mutex outputMutex;
double seconds(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double>(b-a).count(); }
std::string quote(const std::string &s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += c; }
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if (c >= 32) out += c;
    }
    return out + "\"";
}
int run(int argc, char **argv) {
    if (argc < 3) { std::cerr << "Usage: whisper-native MODEL CORPUS.tsv [limitSeconds=60] [pace=0] [stepSeconds=1]\n"; return 2; }
    const double limit = argc > 3 ? std::stod(argv[3]) : 60;
    const bool paced = argc > 4 && std::string(argv[4]) == "1";
    const double step = argc > 5 ? std::stod(argv[5]) : 1;
    const std::string source = argc > 6 ? argv[6] : "systemAudio";
    if (step <= 0 || step > 15) return 2;
    auto start = Clock::now();
    auto config = whisper_context_default_params();
    config.use_gpu = true;
    auto *ctx = whisper_init_from_file_with_params(argv[1], config);
    if (!ctx) return 3;
    {
        std::lock_guard<std::mutex> lock(outputMutex);
        std::cout << "{\"event\":\"load\",\"engine\":\"whisper.cpp\",\"source\":" << quote(source) << ",\"seconds\":" << seconds(start, Clock::now()) << "}\n";
    }
    std::ifstream corpus(argv[2]);
    if (!corpus) { whisper_free(ctx); return 4; }
    double audioSeconds = 0;
    auto origin = Clock::now();
    std::string line;
    while (std::getline(corpus, line) && audioSeconds < limit) {
        std::istringstream fields(line);
        std::string id, file, duration, split, reference;
        std::getline(fields,id,'\t'); std::getline(fields,file,'\t'); std::getline(fields,duration,'\t');
        std::getline(fields,split,'\t'); std::getline(fields,reference);
        std::ifstream input(file, std::ios::binary | std::ios::ate);
        if (!input) { whisper_free(ctx); return 5; }
        size_t total = size_t(input.tellg()) / sizeof(float);
        size_t count = std::min(total, size_t((limit - audioSeconds) * 16000));
        std::vector<float> samples(count);
        input.seekg(0); input.read(reinterpret_cast<char *>(samples.data()), count * sizeof(float));
        std::string text, previous;
        for (size_t pos = 0; pos < count;) {
            size_t end = std::min(count, pos + size_t(step * 16000));
            double sourceEnd = audioSeconds + double(end) / 16000;
            if (paced) std::this_thread::sleep_until(origin + std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(sourceEnd)));
            auto begin = Clock::now();
            // One context per process/source; reset decoder for complete bounded-window re-inference.
            auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            params.n_threads = 6;
            params.language = "en";
            params.no_context = true;
            params.no_timestamps = true;
            params.print_realtime = false;
            params.print_progress = false;
            params.print_timestamps = false;
            params.print_special = false;
            params.temperature_inc = 0;
            if (whisper_full(ctx, params, samples.data(), int(end)) != 0) { whisper_free(ctx); return 6; }
            text.clear();
            for (int i = 0; i < whisper_full_n_segments(ctx); ++i) text += whisper_full_get_segment_text(ctx, i);
            auto done = Clock::now();
            {
            std::lock_guard<std::mutex> lock(outputMutex);
            std::cout << "{\"event\":\"partial\",\"engine\":\"whisper.cpp\",\"source\":" << quote(source) << ",\"fixture\":" << quote(id)
                      << ",\"sourceEnd\":" << sourceEnd << ",\"fixtureEnd\":" << double(end)/16000
                      << ",\"wallElapsed\":" << seconds(origin,done) << ",\"inferenceSeconds\":" << seconds(begin,done)
                      << ",\"backlogSeconds\":" << (paced ? std::max(0.0,seconds(origin,begin)-sourceEnd) : 0)
                      << ",\"changed\":" << (text != previous ? "true" : "false") << ",\"text\":" << quote(text) << "}\n" << std::flush;
            }
            previous = text;
            pos = end;
        }
        {
        std::lock_guard<std::mutex> lock(outputMutex);
        std::cout << "{\"event\":\"final\",\"engine\":\"whisper.cpp\",\"source\":" << quote(source) << ",\"fixture\":" << quote(id)
                  << ",\"split\":" << quote(split) << ",\"duration\":" << double(count)/16000
                  << ",\"text\":" << quote(text) << ",\"reference\":" << quote(reference)
                  << ",\"completeFixture\":" << (count == total ? "true" : "false") << ",\"flushSeconds\":0}\n";
        }
        audioSeconds += double(count) / 16000;
    }
    auto stop = Clock::now();
    whisper_free(ctx);
    {
    std::lock_guard<std::mutex> lock(outputMutex);
    std::cout << "{\"event\":\"end\",\"engine\":\"whisper.cpp\",\"source\":" << quote(source) << ",\"audioSeconds\":" << audioSeconds
              << ",\"wallSeconds\":" << seconds(origin,Clock::now()) << ",\"cleanupSeconds\":" << seconds(stop,Clock::now()) << "}\n";
    }
    return 0;
}
int main(int argc, char **argv) {
    if (argc > 6 && std::string(argv[6]) == "dual") {
        int codes[2] = {0,0};
        std::thread local([&] { std::vector<char*> args(argv,argv+argc); char source[]="localUser"; args[6]=source; codes[0]=run(argc,args.data()); });
        std::thread remote([&] { std::vector<char*> args(argv,argv+argc); char source[]="systemAudio"; args[6]=source; codes[1]=run(argc,args.data()); });
        local.join(); remote.join();
        return std::max(codes[0],codes[1]);
    }
    return run(argc,argv);
}
