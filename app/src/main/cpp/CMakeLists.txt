cmake_minimum_required(VERSION 3.22.1)
project(ztransfer_crop LANGUAGES C CXX)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_STANDARD 17)
set(ARCHIVE "${CMAKE_CURRENT_SOURCE_DIR}/vendor/libjpeg-turbo-3.1.2.tar.gz")
file(SHA256 "${ARCHIVE}" ARCHIVE_SHA)
if(NOT ARCHIVE_SHA STREQUAL "8f0012234b464ce50890c490f18194f913a7b1f4e6a03d6644179fa0f867d0cf")
  message(FATAL_ERROR "Unexpected libjpeg-turbo source archive")
endif()
if(NOT EXISTS "${CMAKE_CURRENT_BINARY_DIR}/vendor/libjpeg-turbo-3.1.2/CMakeLists.txt")
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/vendor")
  file(ARCHIVE_EXTRACT INPUT "${ARCHIVE}" DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/vendor")
endif()
include(ExternalProject)
set(JPEG_BUILD "${CMAKE_CURRENT_BINARY_DIR}/jpeg-build")
ExternalProject_Add(jpeg_external
  SOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/vendor/libjpeg-turbo-3.1.2"
  BINARY_DIR "${JPEG_BUILD}"
  CMAKE_ARGS
    -DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
    -DANDROID_ABI=${ANDROID_ABI}
    -DANDROID_PLATFORM=${ANDROID_PLATFORM}
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON
    -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_SIMD=OFF -DWITH_TURBOJPEG=ON
  BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target turbojpeg-static --parallel 4
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${JPEG_BUILD}/libturbojpeg.a")
add_library(turbojpeg-static STATIC IMPORTED)
set_target_properties(turbojpeg-static PROPERTIES IMPORTED_LOCATION "${JPEG_BUILD}/libturbojpeg.a")
add_dependencies(turbojpeg-static jpeg_external)
add_library(ztransfer_crop SHARED jpeg_crop.cpp)
target_include_directories(ztransfer_crop PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/vendor/libjpeg-turbo-3.1.2/src")
target_link_libraries(ztransfer_crop turbojpeg-static)
# Android 15+ devices with 16 KiB pages.
target_link_options(ztransfer_crop PRIVATE "-Wl,-z,max-page-size=16384")
