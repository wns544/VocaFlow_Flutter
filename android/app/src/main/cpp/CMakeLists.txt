cmake_minimum_required(VERSION 3.22.1)
project(vocaflow_voicevox)

add_library(voicevox_core SHARED IMPORTED)
set_target_properties(voicevox_core PROPERTIES
  IMPORTED_LOCATION
  "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libvoicevox_core.so"
)

add_library(vocaflow_voicevox SHARED voicevox_bridge.cpp)
target_compile_definitions(vocaflow_voicevox PRIVATE VOICEVOX_LOAD_ONNXRUNTIME)
target_include_directories(vocaflow_voicevox PRIVATE include)
target_link_libraries(vocaflow_voicevox voicevox_core log)
