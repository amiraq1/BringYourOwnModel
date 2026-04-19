cmake_minimum_required(VERSION 3.10.2)
project(byom_engine)

# تعريف مسار Llama.cpp
set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp)

# تعطيل بناء البرامج المستقلة والأمثلة لتقليل وقت التجميع واستهلاك الذاكرة
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build llama.cpp as static libs")
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "Disable common utils")
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Disable tests")
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Disable examples")
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Disable server")

# إضافة Llama.cpp كمكتبة ثابتة
add_subdirectory(${LLAMA_DIR} llama_build)

# تجميع مكتبة JNI (الجسر) الخاصة بنا
add_library(llama_engine SHARED native-lib.cpp)

# ربط واجهتنا بمحرك Llama ومكتبة أندرويد للتسجيل (Log)
target_include_directories(llama_engine PRIVATE ${LLAMA_DIR}/include)
target_link_libraries(llama_engine PRIVATE llama log)
