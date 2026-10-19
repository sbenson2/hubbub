# RNNoise v0.2 (xiph/rnnoise, BSD-3-Clause) built as a static library with the
# default C code path (no SIMD run-time dispatch). Model weights are the
# upstream rnnoise_data-0b50c45 release (src/rnnoise_data.c, ~29 MB of C arrays).
cmake_minimum_required(VERSION 3.14)
project(rnnoise C)

add_library(rnnoise STATIC
  src/celt_lpc.c
  src/denoise.c
  src/kiss_fft.c
  src/nnet.c
  src/nnet_default.c
  src/parse_lpcnet_weights.c
  src/pitch.c
  src/rnn.c
  src/rnnoise_tables.c
  src/rnnoise_data.c
)
target_include_directories(rnnoise PUBLIC include PRIVATE src)
set_target_properties(rnnoise PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(rnnoise PRIVATE -Wno-cpp -O2)
endif()
if(MSVC)
  target_compile_definitions(rnnoise PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(rnnoise PRIVATE /W1 /O2)
endif()
