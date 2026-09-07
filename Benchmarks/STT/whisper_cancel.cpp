#include "whisper.h"
#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>

using Clock=std::chrono::steady_clock;
bool shouldAbort(void *value) { return static_cast<std::atomic_bool*>(value)->load(std::memory_order_relaxed); }
int main(int argc,char**argv) {
    if(argc!=3){std::cerr<<"Usage: whisper-cancel MODEL PCM15SECONDS\n";return 2;}
    std::ifstream file(argv[2],std::ios::binary|std::ios::ate);if(!file)return 3;
    size_t count=size_t(file.tellg())/sizeof(float);if(count==0||count>240000)return 3;
    std::vector<float> samples(count);file.seekg(0);file.read(reinterpret_cast<char*>(samples.data()),count*sizeof(float));
    auto config=whisper_context_default_params();config.use_gpu=true;
    auto*ctx=whisper_init_from_file_with_params(argv[1],config);if(!ctx)return 4;
    for(int attempt=0;attempt<9;++attempt) {
        int delay[3]={5,20,50};std::atomic_bool aborted=false,active=true,activeAtCancel=false;
        std::atomic<long long> cancelledAt=0;
        auto params=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.language="en";params.n_threads=6;params.no_context=true;params.no_timestamps=true;params.temperature_inc=0;
        params.print_realtime=false;params.print_progress=false;params.print_timestamps=false;params.print_special=false;
        params.abort_callback=shouldAbort;params.abort_callback_user_data=&aborted;
        std::thread stop([&]{
            std::this_thread::sleep_for(std::chrono::milliseconds(delay[attempt%3]));
            activeAtCancel.store(active.load());
            cancelledAt.store(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count());
            aborted.store(true);
        });
        int result=whisper_full(ctx,params,samples.data(),int(samples.size()));
        auto terminated=Clock::now();active.store(false);stop.join();
        long long end=std::chrono::duration_cast<std::chrono::nanoseconds>(terminated.time_since_epoch()).count();
        double duration=std::max(0.,double(end-cancelledAt.load())/1e9);
        std::cout<<"{\"event\":\"cancellation\",\"engine\":\"whisper.cpp\",\"attempt\":"<<attempt
                 <<",\"cancelDelayMilliseconds\":"<<delay[attempt%3]<<",\"requestActiveAtCancel\":"<<(activeAtCancel.load()?"true":"false")
                 <<",\"cancelToTerminationSeconds\":"<<duration<<",\"resultReturnedAfterCancel\":"<<(activeAtCancel.load()&&result==0?"true":"false")
                 <<",\"nativeReturnCode\":"<<result<<"}\n";
    }
    whisper_free(ctx);return 0;
}
