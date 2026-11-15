cmake_minimum_required(VERSION 3.22)
project(GaEmulator C)
set(CMAKE_C_STANDARD 11)
get_filename_component(REPO "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(MINIJVM_ROOT "${REPO}/android/.deps/miniJVM")
set(CORE "${MINIJVM_ROOT}/minijvm/c")
file(GLOB JVM_SOURCES CONFIGURE_DEPENDS "${CORE}/jvm/*.c" "${CORE}/utils/*.c"
    "${CORE}/utils/https/*.c" "${CORE}/utils/https/mbedtls/library/*.c")
add_library(gaemulator SHARED ${JVM_SOURCES} "${CORE}/utils/mimalloc/src/static.c"
    "${REPO}/ios/native/bridge.c" "${REPO}/ios/native/raster.c" android_bridge.c)
target_include_directories(gaemulator PRIVATE "${REPO}/ios/native" "${CORE}/jvm" "${CORE}/utils"
    "${CORE}/utils/sljit" "${CORE}/utils/https" "${CORE}/utils/https/mbedtls/include"
    "${CORE}/utils/mimalloc/include" "${MINIJVM_ROOT}/mobile/c/gui/stb")
target_compile_options(gaemulator PRIVATE -fvisibility=hidden -Wno-incompatible-pointer-types -Wno-deprecated-declarations)
target_link_options(gaemulator PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(gaemulator PRIVATE log android m dl)
