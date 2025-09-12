cmake_minimum_required(VERSION 3.16)
project(BoxJNI LANGUAGES C)

# Expect Android toolchain and flags via outer invocation.

# Bring in the core minimal library from repo root
set(ROOT_DIR ${CMAKE_CURRENT_LIST_DIR}/../..)
add_subdirectory(${ROOT_DIR} ${CMAKE_CURRENT_BINARY_DIR}/boxcore)

add_library(boxjni SHARED box_jni.c)
target_include_directories(boxjni PRIVATE ${ROOT_DIR}/include)

# Link against minimal core to expose version and future APIs
target_link_libraries(boxjni PRIVATE BoxCoreMinimal)

# JNI requires log on Android for logging if used later
if(ANDROID)
  find_library(log-lib log)
  if(log-lib)
    target_link_libraries(boxjni PRIVATE ${log-lib})
  endif()
endif()

