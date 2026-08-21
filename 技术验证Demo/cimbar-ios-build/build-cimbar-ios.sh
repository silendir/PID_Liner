#!/bin/bash
# build-cimbar-ios.sh — libcimbar decoder iOS xcframework 一键构建
# 依赖: /tmp/opencv (OpenCV 4.14.0 浅克隆, 构建输入不进仓库) + 本目录 CMakeLists.txt + ../libcimbar-src
# 产物: ./dist/CimbarDecoder.xcframework (device arm64 + simulator arm64, 单静态库含 OpenCV core/imgproc)
# 用法: bash build-cimbar-ios.sh [step]   step ∈ {opencv, cimbar, merge, all}(默认 all)；已完成的 step 重跑覆盖
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OPENCV_SRC="${OPENCV_SRC:-/tmp/opencv}"
BUILD="${ROOT}/build"
DIST="${ROOT}/dist"
OPENCV_VER_TAG="4.14.0"   # 上游 tag, 换版本改这里
DEPLOY_TARGET=13.0        # 与主工程 Podfile 一致

STEP="${1:-all}"

# ---------- step 1: OpenCV 裁剪静态库 (core+imgproc) ----------
build_opencv_slice() {  # $1=IOS_PLATFORM(OS|SIMULATOR) $2=outdir
	local platform="$1" outdir="$2"
	echo "==> OpenCV [$platform] -> $outdir"
	cmake -S "$OPENCV_SRC" -B "$outdir" -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE="$OPENCV_SRC/platforms/ios/cmake/Toolchains/iOS.cmake" \
		-DIOS_PLATFORM="$platform" \
		-DIOS_ARCH=arm64 \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
		-DBUILD_LIST=core,imgproc \
		-DBUILD_SHARED_LIBS=OFF \
		-DAPPLE_FRAMEWORK=OFF \
		-DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF \
		-DWITH_ITT=OFF -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_TBB=OFF -DWITH_EIGEN=OFF \
		-DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF -DWITH_OPENJPEG=OFF \
		-DWITH_OPENEXR=OFF -DWITH_CUDA=OFF \
		-DCMAKE_INSTALL_PREFIX="$outdir/install"
	cmake --build "$outdir" --target install
}

# ---------- step 2: libcimbar decode 静态库 ----------
build_cimbar_slice() {  # $1=IOS_PLATFORM(OS|SIMULATOR) $2=opencv_install_dir $3=outdir
	local platform="$1" opencvroot="$2" outdir="$3"
	echo "==> libcimbar [$platform] -> $outdir"
	cmake -S "$ROOT" -B "$outdir" -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE="$OPENCV_SRC/platforms/ios/cmake/Toolchains/iOS.cmake" \
		-DIOS_PLATFORM="$platform" \
		-DIOS_ARCH=arm64 \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
		-DOPENCV_ROOT="$opencvroot"
	cmake --build "$outdir"
}

# ---------- step 3: libtool 合并 + xcframework ----------
merge_and_wrap() {
	echo "==> merge .a + create xcframework"
	local out="$DIST"
	rm -rf "$out"; mkdir -p "$out"

	for slice in device sim; do
		local opencv_libs bdir
		if [ "$slice" = device ]; then opencv_libs="$BUILD/opencv-device/install/lib"; bdir="$BUILD/cimbar-device";
		else opencv_libs="$BUILD/opencv-sim/install/lib"; bdir="$BUILD/cimbar-sim"; fi

		# 收集全部 .a: libcimbar + opencv(含3rdparty)
		local libs=()
		libs+=("$bdir/out/libcimbar_decode.a")
		libs+=($(ls "$opencv_libs"/opencv_*.a 2>/dev/null || true))
		libs+=($(ls "$opencv_libs"/3rdparty/*.a 2>/dev/null || true))
		if [ ${#libs[@]} -lt 2 ]; then echo "!! $slice 缺 .a 产物" >&2; exit 1; fi
		libtool -static -o "$out/CimbarDecoder-$slice.a" "${libs[@]}"
		echo "   $slice: $(du -h "$out/CimbarDecoder-$slice.a" | cut -f1)  <= ${#libs[@]} libs"
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
		build_opencv_slice OS "$BUILD/opencv-device"
		build_opencv_slice SIMULATOR "$BUILD/opencv-sim" ;;
	cimbar)
		build_cimbar_slice OS "$BUILD/opencv-device/install" "$BUILD/cimbar-device"
		build_cimbar_slice SIMULATOR "$BUILD/opencv-sim/install" "$BUILD/cimbar-sim" ;;
	merge)
		merge_and_wrap ;;
	all)
		build_opencv_slice OS "$BUILD/opencv-device"
		build_opencv_slice SIMULATOR "$BUILD/opencv-sim"
		build_cimbar_slice OS "$BUILD/opencv-device/install" "$BUILD/cimbar-device"
		build_cimbar_slice SIMULATOR "$BUILD/opencv-sim/install" "$BUILD/cimbar-sim"
		merge_and_wrap ;;
	*) echo "unknown step: $STEP"; exit 1 ;;
esac
