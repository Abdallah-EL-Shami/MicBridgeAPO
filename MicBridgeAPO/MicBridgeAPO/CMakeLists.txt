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
    target_link_libraries(MicBridgeAPO PRIVATE ws2_32 ole32 iphlpapi)
endif()

if(WIN32)
    # This bootstrap is intentionally non-operational until its independent
    # signature, manifest, file-handle, and handoff checks are implemented.
    add_executable(MicBridgeBootstrap
        src/MicBridgeBootstrap.cpp
        src/MicBridgeBootstrapTrust.cpp
    )
    target_compile_options(MicBridgeBootstrap PRIVATE /W4 /permissive- /EHsc)
    target_compile_definitions(MicBridgeBootstrap PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
    target_link_libraries(MicBridgeBootstrap PRIVATE wintrust crypt32 bcrypt)

    if(BUILD_TESTING)
        add_executable(micbridge_bootstrap_signature_test
            tests/bootstrap_signature_rejects_unsigned.cpp
            src/MicBridgeBootstrapTrust.cpp
        )
        target_include_directories(micbridge_bootstrap_signature_test PRIVATE src)
        target_compile_options(micbridge_bootstrap_signature_test PRIVATE /W4 /permissive- /EHsc)
        target_compile_definitions(micbridge_bootstrap_signature_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
        target_compile_definitions(micbridge_bootstrap_signature_test PRIVATE MICBRIDGE_BOOTSTRAP_TESTING)
        target_link_libraries(micbridge_bootstrap_signature_test PRIVATE wintrust crypt32 bcrypt)
        add_test(NAME micbridge_bootstrap_rejects_unsigned
            COMMAND micbridge_bootstrap_signature_test $<TARGET_FILE:micbridge_bootstrap_fail_closed>)
    endif()
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

    if(WIN32)
        add_executable(micbridge_bootstrap_fail_closed tests/bootstrap_fail_closed.cpp)
        target_compile_options(micbridge_bootstrap_fail_closed PRIVATE /W4 /permissive- /EHsc)
        add_test(NAME micbridge_bootstrap_fail_closed
            COMMAND micbridge_bootstrap_fail_closed $<TARGET_FILE:MicBridgeBootstrap>)
    endif()

    if(WIN32)
        add_executable(micbridge_udp_broadcast_share_smoke tests/udp_broadcast_share_smoke.cpp)
        target_compile_options(micbridge_udp_broadcast_share_smoke PRIVATE /W4 /permissive- /EHsc)
        target_link_libraries(micbridge_udp_broadcast_share_smoke PRIVATE ws2_32)
        add_test(NAME micbridge_udp_broadcast_share_smoke COMMAND micbridge_udp_broadcast_share_smoke)
    endif()

    if(WIN32 AND MICBRIDGE_BUILD_APO)
        add_executable(micbridge_apo_com_smoke tests/apo_com_smoke.cpp)
        target_compile_options(micbridge_apo_com_smoke PRIVATE /W4 /permissive- /EHsc)
        target_link_libraries(micbridge_apo_com_smoke PRIVATE ole32)
        add_test(NAME micbridge_apo_com_smoke
            COMMAND micbridge_apo_com_smoke $<TARGET_FILE:MicBridgeAPO>)
    endif()
endif()
