#ifndef STT_ENDPOINT_VAD_H
#define STT_ENDPOINT_VAD_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct GateVAD GateVAD;
typedef struct {
    int sample_count;
    int speech_samples;
    int silence_samples;
    int can_decode;
    int should_finalize;
    int maximum_reached;
    double start_time;
    double represented_end;
    double speech_end;
} GateVADState;
GateVAD *gate_vad_create(void);
GateVAD *gate_vad_create_config(float rms_floor, int minimum_speech_samples);
void gate_vad_destroy(GateVAD *vad);
void gate_vad_reset(GateVAD *vad);
int gate_vad_append(GateVAD *vad, const float *samples, int count, double timestamp);
GateVADState gate_vad_state(const GateVAD *vad);
const float *gate_vad_samples(const GateVAD *vad);
#ifdef __cplusplus
}
#endif
#endif
