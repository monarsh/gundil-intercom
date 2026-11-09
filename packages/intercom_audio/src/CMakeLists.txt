# Shared native build for Linux, Windows (via ../linux, ../windows) and
# Android (via Gradle externalNativeBuild).
cmake_minimum_required(VERSION 3.10)

project(intercom_audio_library VERSION 1.0.0 LANGUAGES C)

add_library(intercom_audio SHARED
  "intercom_audio.c"
)

set_target_properties(intercom_audio PROPERTIES
  PUBLIC_HEADER intercom_audio.h
  OUTPUT_NAME "intercom_audio"
  C_VISIBILITY_PRESET hidden
)

if (ANDROID)
  # miniaudio loads AAudio / OpenSL ES at runtime via dlopen.
  target_link_libraries(intercom_audio PRIVATE m dl log)
  target_link_options(intercom_audio PRIVATE "-Wl,-z,max-page-size=16384")
elseif (UNIX)
  # miniaudio loads PulseAudio / ALSA at runtime via dlopen.
  find_package(Threads REQUIRED)
  target_link_libraries(intercom_audio PRIVATE Threads::Threads m ${CMAKE_DL_LIBS})
endif()
