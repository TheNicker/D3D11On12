# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
cmake_minimum_required(VERSION 3.14)
project(d3d11on12)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_SYSTEM_VERSION 10.0)
add_compile_definitions(WINVER=0x0A00 _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000000)
add_link_options(/SUBSYSTEM:WINDOWS,10.00 /guard:cf /DYNAMICBASE /NXCOMPAT)
#add_compile_options(/arm64EC)

set(USE_PIX OFF)

add_subdirectory(src)
