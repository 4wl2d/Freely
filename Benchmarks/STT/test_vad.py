import ctypes as c
import unittest
from pathlib import Path
from vad_coverage import library

@unittest.skipUnless((Path(__file__).resolve().parent/'.cache/libEndpointVAD.dylib').exists(),'Build optional native VAD library first')
class VADTests(unittest.TestCase):
    def setUp(self):
        self.lib=library();self.vad=self.lib.gate_vad_create_config(.004,2560)
        self.silence=(c.c_float*320)(*([0]*320));self.speech=(c.c_float*320)(*([.02]*320));self.time=0
    def tearDown(self):self.lib.gate_vad_destroy(self.vad)
    def append(self,signal):
        self.assertEqual(self.lib.gate_vad_append(self.vad,signal,320,self.time),1);self.time+=.02
    def test_preroll_and_450ms_endpoint_include_original_time(self):
        for _ in range(10):self.append(self.silence)
        for _ in range(20):self.append(self.speech)
        for _ in range(22):self.append(self.silence)
        self.assertFalse(self.lib.gate_vad_state(self.vad).should_finalize)
        self.append(self.silence);state=self.lib.gate_vad_state(self.vad)
        self.assertTrue(state.can_decode);self.assertTrue(state.should_finalize)
        self.assertAlmostEqual(state.start_time,0);self.assertAlmostEqual(state.speech_end,.6)
        self.assertAlmostEqual(state.represented_end,1.06)
    def test_capacity_rejects_unconsumed_audio_instead_of_silent_loss(self):
        for _ in range(750):self.append(self.speech)
        state=self.lib.gate_vad_state(self.vad);self.assertEqual(state.sample_count,240000)
        self.assertTrue(state.maximum_reached)
        self.assertEqual(self.lib.gate_vad_append(self.vad,self.speech,320,self.time),0)

if __name__=='__main__':unittest.main()
