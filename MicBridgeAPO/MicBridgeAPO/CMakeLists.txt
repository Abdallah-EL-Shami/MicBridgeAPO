cmake_minimum_required(VERSION 3.20)
project(MicBridgeAPO CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# CRT ساكن حتى لا يحتاج audiodg.exe إلى مكتبات VC وقت التشغيل
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
add_library(MicBridgeAPO SHARED src/MicBridgeAPO.cpp src/MicBridgeAPO.def)
target_compile_definitions(MicBridgeAPO PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WINSOCK_DEPRECATED_NO_WARNINGS)
target_link_libraries(MicBridgeAPO PRIVATE ws2_32 ole32)
