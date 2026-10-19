# Native tests for the Hubbub capture post-processor. Build (Windows):
#   cmake -S hubbub_test -B build -G Ninja && cmake --build build
# apm_probe links the downloaded libwebrtc prebuilt (third_party/libwebrtc).
cmake_minimum_required(VERSION 3.15)
project(hubbub_test CXX C)
set(CMAKE_CXX_STANDARD 17)
get_filename_component(HUBBUB_RNNOISE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../rnnoise" ABSOLUTE)
add_subdirectory("${HUBBUB_RNNOISE_DIR}" rnnoise EXCLUDE_FROM_ALL)
set(LIBWEBRTC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc")

if(EXISTS "${LIBWEBRTC_DIR}/lib/libwebrtc.dll.lib" OR EXISTS "${LIBWEBRTC_DIR}/lib/libwebrtc.so")
add_executable(apm_probe apm_probe.cc "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/src/hubbub_audio.cc")
target_include_directories(apm_probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include")
target_link_libraries(apm_probe PRIVATE rnnoise)
target_compile_definitions(apm_probe PRIVATE LIB_WEBRTC_API_DLL RTC_DESKTOP_DEVICE $<$<BOOL:${MSVC}>:_USE_MATH_DEFINES>)
target_include_directories(apm_probe PRIVATE "${LIBWEBRTC_DIR}/include")
if(WIN32)
  target_link_libraries(apm_probe PRIVATE "${LIBWEBRTC_DIR}/lib/libwebrtc.dll.lib")
  add_custom_command(TARGET apm_probe POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${LIBWEBRTC_DIR}/lib/libwebrtc.dll" $<TARGET_FILE_DIR:apm_probe>)
else()
  target_link_libraries(apm_probe PRIVATE "${LIBWEBRTC_DIR}/lib/libwebrtc.so" pthread)
  set_target_properties(apm_probe PROPERTIES BUILD_RPATH "${LIBWEBRTC_DIR}/lib")
endif()
endif()

# Pure DSP tests, no libwebrtc: frame buffering, resampler, gain/limiter,
# peak meter, RNNoise.
set(PLUGIN_COMMON "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp")
if(MSVC)
  add_compile_options(/W4 /WX /wd4100)
else()
  add_compile_options(-Wall -Wextra -Werror)
endif()
add_executable(hubbub_audio_test hubbub_audio_test.cc "${PLUGIN_COMMON}/src/hubbub_audio.cc")
target_include_directories(hubbub_audio_test PRIVATE "${PLUGIN_COMMON}/include")
target_link_libraries(hubbub_audio_test PRIVATE rnnoise)
if(MSVC)
  target_compile_definitions(hubbub_audio_test PRIVATE _USE_MATH_DEFINES)
endif()
