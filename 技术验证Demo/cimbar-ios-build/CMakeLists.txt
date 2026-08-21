# libcimbar iOS decoder 构建层（非上游文件，属 PID_Liner 工程）
# 用法: 由 build-cimbar-ios.sh 调用，传入 OPENCV_ROOT(安装好的静态库前缀) 与 iOS 工具链
# 产物: libcimbar_decode.a —— 仅 libcimbar 侧; OpenCV .a 由脚本 libtool 合并进最终 xcframework
cmake_minimum_required(VERSION 3.20)
project(cimbar_decode CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_STANDARD 11)
if(NOT CMAKE_BUILD_TYPE)
	set(CMAKE_BUILD_TYPE Release)
endif()

# ---- 路径 ----
set(CIMBAR_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../libcimbar-src" CACHE PATH "vendored libcimbar source")

# ---- 上游编译开关(与上游 WASM 构建对齐) ----
set(DISABLE_TESTS ON)              # 关掉上游各库的 test 子目录
add_definitions(-DGF256_TARGET_MOBILE)   # 移动端优化的 GF256 路径(上游 wasm 同款)
add_definitions(-DLIBCIMBAR_PROJECT_ROOT="${CIMBAR_SRC}")

# ---- 头文件路径: 上游 lib + 树内第三方(全部 header-only: fmt/stb/base91/intx/libpopcnt/...) ----
include_directories(
	${CIMBAR_SRC}/src/lib
	${CIMBAR_SRC}/src/third_party_lib
	${OPENCV_ROOT}/include/opencv4
)

# ---- OpenCV 静态库(core+imgproc, 由脚本先编好安装到 OPENCV_ROOT) ----
find_library(OPENCV_CORE opencv_core PATHS ${OPENCV_ROOT}/lib NO_DEFAULT_PATH REQUIRED)
find_library(OPENCV_IMGPROC opencv_imgproc PATHS ${OPENCV_ROOT}/lib NO_DEFAULT_PATH REQUIRED)

# ---- 上游 5 个需要编译的静态库(其余全是 INTERFACE/header-only) ----
add_subdirectory(${CIMBAR_SRC}/src/lib/cimb_translator build/cimb_translator)
add_subdirectory(${CIMBAR_SRC}/src/lib/extractor build/extractor)
add_subdirectory(${CIMBAR_SRC}/src/third_party_lib/wirehair build/wirehair)
add_subdirectory(${CIMBAR_SRC}/src/third_party_lib/zstd build/zstd)
add_subdirectory(${CIMBAR_SRC}/src/third_party_lib/libcorrect build/libcorrect)

# ---- 解码入口: 上游 cimbar_recv_js.cpp 原样编译(未修改, MPL2.0 文件级合规) ----
add_library(cimbar_decode STATIC
	${CIMBAR_SRC}/src/lib/cimbar_js/cimbar_recv_js.cpp
)
target_link_libraries(cimbar_decode
	cimb_translator
	extractor
	wirehair
	zstd
	correct_static
	${OPENCV_CORE}
	${OPENCV_IMGPROC}
)

set_target_properties(cimbar_decode PROPERTIES ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/out)
