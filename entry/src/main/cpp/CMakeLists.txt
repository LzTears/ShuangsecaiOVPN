cmake_minimum_required(VERSION 3.16)
project(shuangsecai_ovpn LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
get_filename_component(DEPS "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party" ABSOLUTE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
add_subdirectory("${DEPS}/mbedtls" "${CMAKE_CURRENT_BINARY_DIR}/mbedtls" EXCLUDE_FROM_ALL)
add_library(ovpn SHARED ovpn_bridge.cpp
    "${DEPS}/openvpn3/client/ovpncli.cpp"
    "${DEPS}/openvpn3/openvpn/crypto/data_epoch.cpp")
target_include_directories(ovpn PRIVATE "${DEPS}/openvpn3" "${DEPS}/asio/asio/include")
target_compile_definitions(ovpn PRIVATE ASIO_STANDALONE USE_ASIO USE_MBEDTLS USE_TUN_BUILDER
    OPENVPN_CORE_API_VISIBILITY_HIDDEN)
target_compile_options(ovpn PRIVATE -fexceptions -frtti -fvisibility=hidden)
target_link_libraries(ovpn PRIVATE mbedtls mbedx509 mbedcrypto libace_napi.z.so)
