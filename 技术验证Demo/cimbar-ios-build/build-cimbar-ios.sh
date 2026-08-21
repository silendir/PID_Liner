#!/bin/bash
# build-cimbar-ios.sh — libcimbar decoder iOS xcframework 一键构建
# 依赖: /tmp/opencv (OpenCV 4.14.0 源码, 构建输入不进仓库) + 本目录 CMakeLists.txt + ../libcimbar-src
# 产物: ./dist/CimbarDecoder.xcframework (device arm64 + simulator arm64, 单静态库含 OpenCV core/imgproc)
# 用法: bash build-cimbar-ios.sh [step]   step ∈ {opencv, cimbar, merge, all}(默认 all)；重跑覆盖
# 调用模式照抄 opencv/platforms/ios/build_framework.py: Toolchain-{iPhoneOS|iPhoneSimulator}_Xcode.cmake + -GXcode
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OPENCV_SRC="${OPENCV_SRC:-/tmp/opencv}"
BUILD="${ROOT}/build"
DIST="${ROOT}/dist"
DEPLOY_TARGET=13.0        # 与主工程 Podfile 一致
TOOLCHAIN_DEVICE="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneOS_Xcode.cmake"
TOOLCHAIN_SIM="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneSimulator_Xcode.cmake"

export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOY_TARGET"

STEP="${1:-all}"

# ---------- step 1: OpenCV 裁剪静态库 (core+imgproc) ----------
build_opencv_slice() {  # $1=toolchain $2=outdir
	local toolchain="$1" outdir="$2"
	echo "==> OpenCV [$outdir] "
	cmake -S "$OPENCV_SRC" -B "$outdir" -G Xcode \
		-DCMAKE_TOOLCHAIN_FILE="$toolchain" \
		-DIOS_ARCH=arm64 \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_BUILD_TYPE=Release \
		-DIPHONEOS_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
		-DBUILD_LIST=core,imgproc \
		-DBUILD_SHARED_LIBS=OFF \
		-DAPPLE_FRAMEWORK=OFF \
		-DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF \
		-DWITH_ITT=OFF -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_TBB=OFF -DWITH_EIGEN=OFF \
		-DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF -DWITH_OPENJPEG=OFF \
		-DWITH_OPENEXR=OFF -DWITH_CUDA=OFF \
		-DCMAKE_INSTALL_PREFIX="$outdir/install"
	cmake --build "$outdir" --target install --config Release -- CODE_SIGNING_ALLOWED=NO
}

# ---------- step 2: libcimbar decode 静态库 ----------
build_cimbar_slice() {  # $1=toolchain $2=opencv_install_dir $3=outdir
	local toolchain="$1" opencvroot="$2" outdir="$3"
	echo "==> libcimbar [$outdir]"
	cmake -S "$ROOT" -B "$outdir" -G Xcode \
		-DCMAKE_TOOLCHAIN_FILE="$toolchain" \
		-DIOS_ARCH=arm64 \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_BUILD_TYPE=Release \
		-DIPHONEOS_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
		-DOPENCV_ROOT="$opencvroot"
	cmake --build "$outdir" --config Release -- CODE_SIGNING_ALLOWED=NO
}

# ---------- step 3: libtool 合并 + xcframework ----------
merge_and_wrap() {
	echo "==> merge .a + create xcframework"
	local out="$DIST"
	rm -rf "$out"; mkdir -p "$out"

	for slice in device sim; do
		local opencv_build opencv_install bdir
		if [ "$slice" = device ]; then opencv_build="$BUILD/opencv-device"; opencv_install="$BUILD/opencv-device/install/lib"; bdir="$BUILD/cimbar-device";
		else opencv_build="$BUILD/opencv-sim"; opencv_install="$BUILD/opencv-sim/install/lib"; bdir="$BUILD/cimbar-sim"; fi

		# 收集全部 .a: libcimbar 全部目标库(STATIC target 互不吸收, 各自独立 .a 散在 build 树)
		#            + opencv 主库 + 3rdparty(kleidicv/zlib 在 build 树, install 不拷贝)
		local libs=()
		libs+=($(find "$bdir" -name "*.a" -path "*Release*" 2>/dev/null))
		libs+=("$opencv_install"/libopencv_*.a)
		libs+=("$opencv_build"/3rdparty/lib/*/*.a)
		libs+=("$opencv_build"/build/kleidicv_neon.build/*/"libkleidicv_neon.a")
		local unique_libs=($(printf '%s\n' "${libs[@]}" | awk '!seen[$0]++'))
		if [ ${#unique_libs[@]} -lt 2 ] || [ ! -f "${unique_libs[0]}" ]; then echo "!! $slice 缺 .a 产物: ${unique_libs[*]}" >&2; exit 1; fi
		libtool -static -o "$out/CimbarDecoder-$slice.a" "${unique_libs[@]}"
		echo "   $slice: $(du -h "$out/CimbarDecoder-$slice.a" | cut -f1)  <= ${#unique_libs[@]} libs"
	done

	rm -rf "$out/CimbarDecoder.xcframework"
	xcodebuild -create-xcframework \
		-library "$out/CimbarDecoder-device.a" -headers "$ROOT/include" \
		-library "$out/CimbarDecoder-sim.a" -headers "$ROOT/include" \
		-output "$out/CimbarDecoder.xcframework"
	echo "✅ $out/CimbarDecoder.xcframework"
}

case "$STEP" in
	opencv)
		build_opencv_slice "$TOOLCHAIN_DEVICE" "$BUILD/opencv-device"
		build_opencv_slice "$TOOLCHAIN_SIM" "$BUILD/opencv-sim" ;;
	cimbar)
		build_cimbar_slice "$TOOLCHAIN_DEVICE" "$BUILD/opencv-device/install" "$BUILD/cimbar-device"
		build_cimbar_slice "$TOOLCHAIN_SIM" "$BUILD/opencv-sim/install" "$BUILD/cimbar-sim" ;;
	merge)
		merge_and_wrap ;;
	all)
		build_opencv_slice "$TOOLCHAIN_DEVICE" "$BUILD/opencv-device"
		build_opencv_slice "$TOOLCHAIN_SIM" "$BUILD/opencv-sim"
		build_cimbar_slice "$TOOLCHAIN_DEVICE" "$BUILD/opencv-device/install" "$BUILD/cimbar-device"
		build_cimbar_slice "$TOOLCHAIN_SIM" "$BUILD/opencv-sim/install" "$BUILD/cimbar-sim"
		merge_and_wrap ;;
	*) echo "unknown step: $STEP"; exit 1 ;;
esac
