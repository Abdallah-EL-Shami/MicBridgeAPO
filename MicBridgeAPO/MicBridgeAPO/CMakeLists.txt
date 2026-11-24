cmake_minimum_required(VERSION 3.20)
project(MicBridgeAPO LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)
option(MICBRIDGE_BUILD_APO "Build the Windows Audio Processing Object DLL" ON)

if(MICBRIDGE_BUILD_APO)
    if(NOT WIN32)
        message(FATAL_ERROR "MicBridgeAPO is Windows-only. Use -DMICBRIDGE_BUILD_APO=OFF to build portable core tests.")
    endif()

    # Static CRT keeps audiodg.exe independent of a separately installed VC runtime.
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

    add_library(MicBridgeAPO SHARED
        src/MicBridgeAPO.cpp
        src/MicBridgeAPO.def
    )
    target_compile_definitions(MicBridgeAPO PRIVATE
        UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
        _WINSOCK_DEPRECATED_NO_WARNINGS
    )
    target_compile_options(MicBridgeAPO PRIVATE /W4 /permissive- /EHsc)
    target_link_libraries(MicBridgeAPO PRIVATE ws2_32 ole32)
endif()

if(BUILD_TESTING)
    add_executable(micbridge_core_tests tests/core_tests.cpp)
    target_include_directories(micbridge_core_tests PRIVATE src)
    if(MSVC)
        target_compile_options(micbridge_core_tests PRIVATE /W4 /permissive- /EHsc)
    else()
        target_compile_options(micbridge_core_tests PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME micbridge_core_tests COMMAND micbridge_core_tests)
endif()
