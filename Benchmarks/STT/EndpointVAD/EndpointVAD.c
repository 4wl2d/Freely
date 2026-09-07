#include "EndpointVAD.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

struct GateVAD {
    float samples[240000];
    float preroll[3200];
    int count, preroll_count, silence, speech;
    float noise_rms;
    float rms_floor;
    int minimum_speech_samples;
    double start, represented_end, speech_end;
};
GateVAD *gate_vad_create(void) {
    return gate_vad_create_config(.004f, 2560);
}
GateVAD *gate_vad_create_config(float rms_floor, int minimum_speech_samples) {
    if (!isfinite(rms_floor) || rms_floor <= 0 || rms_floor > .012f || minimum_speech_samples <= 0) return NULL;
    GateVAD *vad = (GateVAD *)calloc(1, sizeof(GateVAD));
    if (vad) { vad->noise_rms = .001f; vad->rms_floor = rms_floor; vad->minimum_speech_samples = minimum_speech_samples; }
    return vad;
}
void gate_vad_destroy(GateVAD *vad) { free(vad); }
void gate_vad_reset(GateVAD *vad) {
    vad->count = vad->preroll_count = vad->silence = vad->speech = 0;
    vad->start = vad->represented_end = vad->speech_end = 0;
}
int gate_vad_append(GateVAD *vad, const float *samples, int count, double timestamp) {
    if (!vad || !samples || count <= 0 || count > 320 || !isfinite(timestamp) || count > 240000 - vad->count) return 0;
    float sum = 0;
    for (int i = 0; i < count; ++i) sum += samples[i] * samples[i];
    float rms = sqrtf(sum / (float)count);
    int speech = rms >= fmaxf(vad->rms_floor, fminf(.012f, vad->noise_rms * 3));
    if (!vad->count) {
        if (!speech) {
            vad->noise_rms = vad->noise_rms * .98f + rms * .02f;
            int remove = vad->preroll_count + count - 3200;
            if (remove > 0) {
                memmove(vad->preroll, vad->preroll + remove, (vad->preroll_count - remove) * sizeof(float));
                vad->preroll_count -= remove;
            }
            memcpy(vad->preroll + vad->preroll_count, samples, count * sizeof(float));
            vad->preroll_count += count;
            return 1;
        }
        memcpy(vad->samples, vad->preroll, vad->preroll_count * sizeof(float));
        vad->count = vad->preroll_count;
        vad->start = timestamp - (double)vad->preroll_count / 16000;
        vad->preroll_count = 0;
    }
    int accepted = count < 240000 - vad->count ? count : 240000 - vad->count;
    memcpy(vad->samples + vad->count, samples, accepted * sizeof(float));
    vad->count += accepted;
    vad->represented_end = vad->start + (double)vad->count / 16000;
    if (speech) { vad->speech += count; vad->silence = 0; vad->speech_end = timestamp + (double)count / 16000; }
    else vad->silence += count;
    return 1;
}
GateVADState gate_vad_state(const GateVAD *vad) {
    GateVADState state = {vad->count, vad->speech, vad->silence,
                         vad->speech >= vad->minimum_speech_samples && vad->count >= 5120,
                         vad->count > 0 && (vad->silence >= 7200 || vad->count >= 240000),
                         vad->count >= 240000, vad->start, vad->represented_end, vad->speech_end};
    return state;
}
const float *gate_vad_samples(const GateVAD *vad) { return vad->samples; }
