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
# Keep Debug easy to inspect. Release uses size optimization and ThinLTO across
# the static codec and JNI wrapper, without changing JPEG algorithms or features.
set(JPEG_C_FLAGS "-ffunction-sections -fdata-sections")
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(JPEG_C_FLAGS "${JPEG_C_FLAGS} -flto=thin")
endif()
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
    "-DCMAKE_C_FLAGS=${JPEG_C_FLAGS}"
    "-DCMAKE_C_FLAGS_RELEASE=-Os -DNDEBUG"
    "-DCMAKE_C_FLAGS_RELWITHDEBINFO=-Os -g -DNDEBUG"
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON
    -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_SIMD=OFF -DWITH_TURBOJPEG=ON
  BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target turbojpeg-static --parallel 4
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${JPEG_BUILD}/libturbojpeg.a")
add_library(turbojpeg-static STATIC IMPORTED)
set_target_properties(turbojpeg-static PROPERTIES IMPORTED_LOCATION "${JPEG_BUILD}/libturbojpeg.a")
add_dependencies(turbojpeg-static jpeg_external)
add_library(ztransfer_crop SHARED jpeg_crop.cpp photo_lut.cpp)
# Keep the hot LUT loop optimized in Debug too; preserve the existing float rounding.
set_source_files_properties(photo_lut.cpp PROPERTIES COMPILE_OPTIONS "-O2;-ffp-contract=off;-fno-fast-math")
# JNI reports failures as Java exceptions; this wrapper uses neither C++
# exceptions nor RTTI and requires no C++ standard-library objects.
target_compile_options(ztransfer_crop PRIVATE -fno-exceptions -fno-rtti)
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
  target_compile_options(ztransfer_crop PRIVATE -Os -flto=thin)
  target_link_options(ztransfer_crop PRIVATE -flto=thin)
endif()
target_include_directories(ztransfer_crop PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/vendor/libjpeg-turbo-3.1.2/src")
target_link_libraries(ztransfer_crop turbojpeg-static)
# Only the JNI entry points are public. Keeping the entire codec API exported
# prevents the linker from removing unused compression/decompression helpers.
set(CROP_EXPORTS "${CMAKE_CURRENT_SOURCE_DIR}/crop.exports")
set_property(TARGET ztransfer_crop APPEND PROPERTY LINK_DEPENDS "${CROP_EXPORTS}")
target_link_options(ztransfer_crop PRIVATE
  "-Wl,--version-script=${CROP_EXPORTS}" "-Wl,--gc-sections")
# Android 15+ devices with 16 KiB pages.
target_link_options(ztransfer_crop PRIVATE "-Wl,-z,max-page-size=16384")
