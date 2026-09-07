#!/bin/bash
set -euo pipefail
STT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STT_ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mode="${1:-help}"
case "$mode" in
  build)
    swift build -c release
    if [[ ! -x .cache/venv/bin/python ]]; then uv venv .cache/venv --python 3.12; fi
    uv pip sync --python .cache/venv/bin/python python-requirements.lock
    if [[ ! -d .cache/whisper.cpp/.git ]]; then git clone --depth 1 --branch v1.9.3 https://github.com/ggml-org/whisper.cpp.git .cache/whisper.cpp; fi
    revision="$(git -C .cache/whisper.cpp rev-parse HEAD)"
    [[ "$revision" == 371b5a7561823ab2bb32142d2751e35e7534727b ]] || { echo 'Unexpected whisper.cpp revision' >&2; exit 1; }
    .cache/venv/bin/cmake -S .cache/whisper.cpp -B .cache/whisper-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF
    .cache/venv/bin/cmake --build .cache/whisper-build -j 8
    clang++ -std=c++17 -O3 -arch arm64 -mmacosx-version-min=15.0 -I .cache/whisper.cpp/include -I .cache/whisper.cpp/ggml/include whisper_native.cpp -L .cache/whisper-build/bin -lwhisper -Wl,-rpath,"$STT_ROOT/.cache/whisper-build/bin" -o .cache/whisper-native
    clang -O3 -arch arm64 -mmacosx-version-min=15.0 -I EndpointVAD/include -c EndpointVAD/EndpointVAD.c -o .cache/EndpointVAD.o
    clang -dynamiclib -O3 -arch arm64 -mmacosx-version-min=15.0 -I EndpointVAD/include EndpointVAD/EndpointVAD.c -o .cache/libEndpointVAD.dylib
    clang++ -std=c++17 -O3 -arch arm64 -mmacosx-version-min=15.0 -I EndpointVAD/include -I .cache/whisper.cpp/include -I .cache/whisper.cpp/ggml/include whisper_endpoint.cpp .cache/EndpointVAD.o -L .cache/whisper-build/bin -lwhisper -Wl,-rpath,"$STT_ROOT/.cache/whisper-build/bin" -o .cache/whisper-endpoint
    clang++ -std=c++17 -O3 -arch arm64 -mmacosx-version-min=15.0 -I .cache/whisper.cpp/include -I .cache/whisper.cpp/ggml/include whisper_cancel.cpp -L .cache/whisper-build/bin -lwhisper -Wl,-rpath,"$STT_ROOT/.cache/whisper-build/bin" -o .cache/whisper-cancel
    ;;
  corpus) python3 prepare_corpus.py --download ;;
  paired)
    python3 prepare_dual_corpus.py
    python3 prepare_questions.py
    ;;
  synthetic) .cache/venv/bin/python prepare_synthetic.py ;;
  synthetic-test)
    .cache/venv/bin/python prepare_synthetic.py
    .build/release/stt-gate fluid-tdt .cache/synthetic-speech-v1/corpus.json .cache/models 120 0 .32 > results/fluid-tdt-synthetic-regression.jsonl 2> .cache/fluid-tdt-synthetic-regression.stderr
    .cache/whisper-native .cache/ggml-base.en.bin .cache/synthetic-speech-v1/corpus.tsv 120 0 .32 > results/whisper-cpp-synthetic-regression.jsonl 2> .cache/whisper-cpp-synthetic-regression.stderr
    python3 analyze_synthetic.py
    ;;
  model) python3 fetch_verified_model.py ;;
  models)
    python3 fetch_verified_model.py
    python3 fetch_candidates.py
    ;;
  test)
    mkdir -p .cache
    clang -dynamiclib -O3 -arch arm64 -mmacosx-version-min=15.0 -I EndpointVAD/include EndpointVAD/EndpointVAD.c -o .cache/libEndpointVAD.dylib
    python3 -m unittest discover -s . -p 'test_*.py'
    ;;
  initial)
    mkdir -p results
    for engine in fluid-tdt fluid-eou whisperkit; do
      model_cache=.cache/models
      if [[ "$engine" == whisperkit ]]; then model_cache=.cache/whisperkit-models; fi
      /usr/bin/time -l .build/release/stt-gate "$engine" .cache/corpus-v1/corpus.json "$model_cache" 60 0 1 > "results/$engine-repeat-initial.jsonl" 2> ".cache/$engine-repeat-initial.stderr"
    done
    /usr/bin/time -l .cache/venv/bin/python mlx_stream.py .cache/corpus-v1/corpus.json --model "$STT_ROOT/.cache/mlx-model" --limit 60 > results/mlx-repeat-initial.jsonl 2> .cache/mlx-repeat-initial.stderr
    [[ -f .cache/ggml-base.en.bin ]] || { echo 'Download the pinned ggml-base.en.bin listed in candidate-versions.json first' >&2; exit 1; }
    /usr/bin/time -l .cache/whisper-native .cache/ggml-base.en.bin .cache/corpus-v1/corpus.tsv 60 0 1 > results/whisper-cpp-repeat-initial.jsonl 2> .cache/whisper-cpp-repeat-initial.stderr
    ;;
  dual)
    python3 dual_replay.py fluid-tdt --seconds "${2:-1200}" --step .32
    python3 dual_replay.py whisper.cpp --seconds "${2:-1200}" --step .32
    ;;
  heldout)
    /usr/bin/time -l .build/release/stt-gate fluid-tdt .cache/corpus-v1/heldout.json .cache/models 300 1 .32 > results/fluid-tdt-heldout.jsonl 2> .cache/fluid-tdt-heldout.stderr
    /usr/bin/time -l .cache/whisper-native .cache/ggml-base.en.bin .cache/corpus-v1/heldout.tsv 300 1 .32 > results/whisper-cpp-heldout.jsonl 2> .cache/whisper-cpp-heldout.stderr
    ;;
  cancel)
    .build/release/stt-gate fluid-tdt .cache/corpus-v1/calibration.json .cache/models 15 0 .32 cancel > results/fluid-tdt-cancellation.jsonl
    ;;
  *) echo 'Usage: Benchmarks/STT/run.sh {build|corpus|paired|synthetic|synthetic-test|model|models|test|initial|dual [seconds]|heldout|cancel}' ;;
esac
