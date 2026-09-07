#include "whisper.h"
#include "EndpointVAD.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;
std::mutex outputMutex;
double elapsed(Clock::time_point start) { return std::chrono::duration<double>(Clock::now() - start).count(); }
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
void emit(const std::string &text) { std::lock_guard<std::mutex> lock(outputMutex); std::cout << text << '\n' << std::flush; }
std::vector<std::string> tokens(const std::string &text) {
    std::vector<std::string> result; std::string word;
    for (unsigned char c : text) {
        if (c < 128 && (std::isalnum(c) || c == '\'')) word += char(std::tolower(c));
        else if (!word.empty()) { result.push_back(word); word.clear(); }
    }
    if (!word.empty()) result.push_back(word);
    return result;
}
bool recognizes(const std::string &text, const std::string &reference) {
    auto actual = tokens(text), expected = tokens(reference);
    if (expected.size() > 2) expected.erase(expected.begin(), expected.end() - 2);
    if (expected.empty() || actual.size() < expected.size()) return false;
    return std::search(actual.begin(),actual.end(),expected.begin(),expected.end()) != actual.end();
}
struct Word { double start, end; std::string text; };
struct Question { double end; std::string text; };
struct Fixture { std::string id, file, split, reference; double duration; };

int run(int argc, char **argv) {
    if (argc < 5) return 2;
    const double limit = argc > 5 ? std::stod(argv[5]) : 1200;
    const bool paced = argc > 6 && std::string(argv[6]) == "1";
    const double step = argc > 7 ? std::stod(argv[7]) : .32;
    const std::string source = argc > 8 ? argv[8] : "systemAudio";
    if (!std::isfinite(limit) || limit < 0 || !std::isfinite(step) || step <= 0 || step > 15) return 2;
    std::vector<Fixture> fixtures;
    std::vector<Question> questions;
    std::vector<Word> words;
    std::string line, a, b;
    std::ifstream corpus(argv[2]), questionFile(argv[3]), wordFile(argv[4]);
    if (!corpus || !questionFile || !wordFile) return 3;
    while (std::getline(corpus,line)) { std::istringstream in(line); Fixture f; std::getline(in,f.id,'\t'); std::getline(in,f.file,'\t'); std::getline(in,a,'\t'); f.duration=std::stod(a); std::getline(in,f.split,'\t');std::getline(in,f.reference);fixtures.push_back(f); }
    while (std::getline(questionFile,line)) { if(line.empty())continue;std::istringstream in(line);Question q;std::getline(in,a,'\t');q.end=std::stod(a);std::getline(in,q.text);questions.push_back(q); }
    while (std::getline(wordFile,line)) { if(line.empty())continue;std::istringstream in(line);Word w;std::getline(in,a,'\t');std::getline(in,b,'\t');w.start=std::stod(a);w.end=std::stod(b);std::getline(in,w.text);words.push_back(w); }
    auto load = Clock::now();
    auto config = whisper_context_default_params(); config.use_gpu=true;
    std::unique_ptr<whisper_context,decltype(&whisper_free)> ctx(whisper_init_from_file_with_params(argv[1],config),whisper_free);
    const char *floorValue=std::getenv(source=="localUser"?"STT_GATE_MIC_RMS_FLOOR":"STT_GATE_SYSTEM_RMS_FLOOR");
    const char *minimumValue=std::getenv("STT_GATE_MIN_SPEECH_SAMPLES");
    float rmsFloor=floorValue?std::stof(floorValue):.004f;int minimumSpeech=minimumValue?std::stoi(minimumValue):2560;
    std::unique_ptr<GateVAD,decltype(&gate_vad_destroy)> vad(gate_vad_create_config(rmsFloor,minimumSpeech),gate_vad_destroy);
    if (!ctx || !vad) return 4;
    emit("{\"event\":\"load\",\"engine\":\"whisper.cpp\",\"mode\":\"endpoint\",\"source\":"+quote(source)+",\"paced\":"+(paced?"true":"false")+",\"rmsFloor\":"+std::to_string(rmsFloor)+",\"minimumSpeechSamples\":"+std::to_string(minimumSpeech)+",\"seconds\":"+std::to_string(elapsed(load))+"}");
    auto origin=Clock::now();
    size_t offered=0, maximum=size_t(limit*16000); int frames=0,segment=0;
    double lastDecode=0,lastFinal=0,vadCPU=0;
    std::string previous, previousTail;
    for(size_t fi=0;fi<fixtures.size() && offered<maximum;++fi) {
        const auto &f=fixtures[fi]; std::ifstream input(f.file,std::ios::binary|std::ios::ate); if(!input)return 5;
        size_t count=std::min(size_t(input.tellg())/sizeof(float),maximum-offered);
        std::vector<float> samples(count);input.seekg(0);input.read(reinterpret_cast<char*>(samples.data()),count*sizeof(float));
        for(size_t pos=0;pos<count;pos+=320) {
            size_t end=std::min(count,pos+320); double timestamp=double(offered)/16000;offered+=end-pos;double sourceEnd=double(offered)/16000;
            if(paced)std::this_thread::sleep_until(origin+std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(sourceEnd)));
            auto vadStart=Clock::now();if(!gate_vad_append(vad.get(),samples.data()+pos,int(end-pos),timestamp))return 6;
            auto state=gate_vad_state(vad.get());vadCPU+=elapsed(vadStart);++frames;
            bool eof=offered>=maximum || (fi+1==fixtures.size() && end==count);
            bool final=state.should_finalize || (eof && state.sample_count>0);
            bool decode=state.can_decode && (final || sourceEnd-lastDecode>=step-.000001);
            std::string text=previous;double done=elapsed(origin);
            if(decode) {
                auto params=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
                params.n_threads=6;params.language="en";params.no_context=true;params.no_timestamps=true;
                params.print_realtime=false;params.print_progress=false;params.print_timestamps=false;params.print_special=false;params.temperature_inc=0;
                double begin=elapsed(origin);
                if(whisper_full(ctx.get(),params,gate_vad_samples(vad.get()),state.sample_count)!=0)return 7;
                text.clear();for(int i=0;i<whisper_full_n_segments(ctx.get());++i)text+=whisper_full_get_segment_text(ctx.get(),i);
                done=elapsed(origin);std::ostringstream row;row.precision(12);
                row<<"{\"event\":\"partial\",\"engine\":\"whisper.cpp\",\"source\":"<<quote(source)<<",\"fixture\":"<<quote(source+"-vad-"+std::to_string(segment))
                   <<",\"sourceEnd\":"<<sourceEnd<<",\"windowStart\":"<<state.start_time<<",\"fixtureEnd\":"<<sourceEnd-state.start_time
                   <<",\"wallElapsed\":"<<done<<",\"inferenceSeconds\":"<<done-begin<<",\"backlogSeconds\":"<<(paced?std::max(0.,begin-sourceEnd):0.)
                   <<",\"text\":"<<quote(text)<<",\"changed\":"<<(text!=previous?"true":"false")<<",\"inputSeconds\":"<<double(state.sample_count)/16000<<"}";emit(row.str());
                previous=text;lastDecode=sourceEnd;
            }
            if(final) {
                std::string reason=state.maximum_reached?"maximumWindow":state.silence_samples>=7200?"silence":"endOfFixture";
                double referenceEnd=-1;std::string reference;
                for(const auto &w:words)if(w.start>=state.start_time && w.start<sourceEnd){referenceEnd=std::max(referenceEnd,w.end);reference+=w.text+" ";}
                std::ostringstream row;row.precision(12);
                row<<"{\"event\":\"final\",\"engine\":\"whisper.cpp\",\"source\":"<<quote(source)<<",\"fixture\":"<<quote(source+"-vad-"+std::to_string(segment))
                   <<",\"duration\":"<<double(state.sample_count)/16000<<",\"sourceEnd\":"<<sourceEnd<<",\"windowStart\":"<<state.start_time
                   <<",\"vadSpeechEnd\":"<<state.speech_end<<",\"wallElapsed\":"<<done<<",\"finalizationFromVADSeconds\":"<<done-state.speech_end
                   <<",\"referenceSpeechEnd\":"<<(referenceEnd>=0?std::to_string(referenceEnd):"null")<<",\"finalizationFromReferenceSeconds\":"<<(referenceEnd>=0?std::to_string(done-referenceEnd):"null")
                   <<",\"reason\":"<<quote(reason)<<",\"decoded\":"<<(state.can_decode?"true":"false")<<",\"text\":"<<quote(state.can_decode?text:"")
                   <<",\"reference\":"<<quote(reference)<<",\"completeFixture\":true,\"flushSeconds\":0}";emit(row.str());
                for(const auto &q:questions)if(q.end>lastFinal && q.end<=sourceEnd) {
                    bool recognized=state.can_decode && q.end>=state.start_time && recognizes(previousTail+" "+text,q.text);
                    emit("{\"event\":\"questionFinal\",\"engine\":\"whisper.cpp\",\"source\":"+quote(source)+",\"questionEnd\":"+std::to_string(q.end)+",\"questionReference\":"+quote(q.text)+",\"recognizedTail\":"+(recognized?"true":"false")+",\"delaySeconds\":"+std::to_string(done-q.end)+",\"endpointReason\":"+quote(reason)+",\"windowStart\":"+std::to_string(state.start_time)+",\"sourceEnd\":"+std::to_string(sourceEnd)+"}");
                }
                auto tail=tokens(previousTail+" "+text);previousTail.clear();for(size_t i=tail.size()>20?tail.size()-20:0;i<tail.size();++i)previousTail+=tail[i]+" ";
                previous.clear();lastFinal=sourceEnd;lastDecode=sourceEnd;++segment;gate_vad_reset(vad.get());
            }
        }
    }
    double duration=double(offered)/16000;std::string reference;int questionCount=0;
    for(const auto&w:words)if(w.start<duration)reference+=w.text+" ";for(const auto&q:questions)if(q.end<=duration)++questionCount;
    auto stop=Clock::now();ctx.reset();
    emit("{\"event\":\"end\",\"engine\":\"whisper.cpp\",\"source\":"+quote(source)+",\"mode\":\"endpoint\",\"paced\":"+(paced?"true":"false")+",\"audioSeconds\":"+std::to_string(duration)+",\"frames20ms\":"+std::to_string(frames)+",\"segments\":"+std::to_string(segment)+",\"vadCPUSeconds\":"+std::to_string(vadCPU)+",\"wallSeconds\":"+std::to_string(elapsed(origin))+",\"cleanupSeconds\":"+std::to_string(elapsed(stop))+",\"reference\":"+quote(reference)+",\"annotatedQuestionCount\":"+std::to_string(questionCount)+"}");
    return 0;
}
int main(int argc,char**argv) {
    if(argc>8 && std::string(argv[8])=="dual") {
        int codes[2]={0,0};
        std::thread local([&]{std::vector<char*> args(argv,argv+argc);char source[]="localUser";args[8]=source;codes[0]=run(argc,args.data());});
        std::thread remote([&]{std::vector<char*> args(argv,argv+argc);char source[]="systemAudio";args[8]=source;if(argc>11){args[2]=argv[9];args[3]=argv[10];args[4]=argv[11];}codes[1]=run(argc,args.data());});
        local.join();remote.join();return std::max(codes[0],codes[1]);
    }
    try{return run(argc,argv);}catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 2;}
}
