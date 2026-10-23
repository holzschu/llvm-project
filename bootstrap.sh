#! /bin/bash
# With contributions from Ian McDowell: https://github.com/IMcD23

# Bail out on error
set -euo pipefail
CLEAN=NO

LLVM_SRCDIR=$(pwd)
OSX_BUILDDIR=$(pwd)/build_osx
IOS_BUILDDIR=$(pwd)/build-iphoneos
SIM_BUILDDIR=$(pwd)/build-iphonesimulator

echo "Downloading ios_system Framework:"
IOS_SYSTEM_VER="v3.0.5"
HHROOT="https://github.com/holzschu"

if [ ! -f ios_error.h ]; then
  curl --fail --location --retry 3 "$HHROOT/ios_system/releases/download/$IOS_SYSTEM_VER/ios_error.h" -o ios_error.h
  echo '51d46b912eb30399cbb5c36c8c8f15eb1a44adcfc9ee581304ac9d3739a84716  ios_error.h' | shasum -a 256 -c -
fi
if [ ! -d ios_system.xcframework ]; then
  curl --fail --location --retry 3 "$HHROOT/ios_system/releases/download/$IOS_SYSTEM_VER/ios_system.xcframework.zip" -o ios_system.xcframework.zip
  echo 'd429e68102926f58bedd8e8b7105dcd169478cd6da1cef494a5f468482d1c8f5  ios_system.xcframework.zip' | shasum -a 256 -c -
  unzip -q ios_system.xcframework.zip
  rm ios_system.xcframework.zip
fi

OSX_SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
IOS_SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path)

# Parse arguments
SDK=all
for i in "$@"
do
case $i in
  -c|--clean)
    CLEAN=YES
  shift
  ;;
  --sdk=iphoneos|--sdk=iphonesimulator)
    SDK=${i#--sdk=}
  ;;
  --sdk=*)
    echo "Unsupported SDK: ${i#--sdk=}" >&2
    exit 2
  ;;
  *)
    # unknown option
  ;;
esac
done

# compile for OSX (about 1h, 1GB of disk space)
echo "Compiling for OSX:"
if [ "$CLEAN" = YES ]; then
  rm -rf $OSX_BUILDDIR
fi
if [ ! -d $OSX_BUILDDIR ]; then
  mkdir $OSX_BUILDDIR
fi
# building with -DLLVM_LINK_LLVM_DYLIB (= single big shared lib) 
# Easier to make a framework with
# libc; impossible to configure
pushd $OSX_BUILDDIR
cmake -G Ninja \
-DLLVM_PARALLEL_LINK_JOBS="${LLVM_LINK_JOBS:-}" \
-DLLVM_TARGETS_TO_BUILD="AArch64;X86;WebAssembly" \
-DLLVM_ENABLE_PROJECTS='clang;compiler-rt;lld;lldb' \
-DLLVM_ENABLE_EH=ON \
-DLLVM_ENABLE_RTTI=ON \
-DLLVM_LINK_LLVM_DYLIB=ON \
-DLLDB_INCLUDE_TESTS=OFF \
-DCMAKE_BUILD_TYPE=Release \
-DCMAKE_OSX_SYSROOT=${OSX_SDKROOT} \
-DCMAKE_C_COMPILER=$(xcrun --sdk macosx -f clang) \
-DCMAKE_CXX_COMPILER=$(xcrun --sdk macosx -f clang++) \
-DCMAKE_ASM_COMPILER=$(xcrun --sdk macosx -f cc) \
-DCMAKE_LIBRARY_PATH=${OSX_SDKROOT}/lib/ \
-DCMAKE_INCLUDE_PATH=${OSX_SDKROOT}/include/ \
../llvm
ninja ${NINJA_JOBS:+-j"$NINJA_JOBS"} llvm-tblgen clang-tblgen lldb-tblgen
popd
# libtool: where? /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool

# Build the static libraries and objects linked by the framework project.
framework_dependencies=$(plutil -convert json -o - "$LLVM_SRCDIR/frameworks/frameworks.xcodeproj/project.pbxproj" | jq -r '
  .objects as $o | $o[] | select(.isa == "PBXNativeTarget") | .buildPhases[] |
  $o[.] | select(.isa == "PBXFrameworksBuildPhase") | .files[] |
  $o[.].fileRef | $o[.].path | select(test("\\.(a|o|dylib)$")) |
  sub("^\\./"; "") | select(. != "lib/libclang_tool.a" and . != "lib/libopt.a")' | sort -u)
framework_targets=()
while IFS= read -r dependency; do
  framework_targets+=("$dependency")
done <<< "$framework_dependencies"
[ "${#framework_targets[@]}" -gt 0 ]

if [ "$SDK" != iphonesimulator ]; then
# Now, compile for iOS using the previous build:
# About 1h, 12 GB of disk space
# -DLLVM_ENABLE_THREADS=OFF is necessary to run commands multiple times
# -I${OSX_BUILDDIR}/include/c++/v1/
# Try to reduce inlining (doesn't work at compile time)
#  -D_LIBCPP_INLINE_VISIBILITY=\"\" -D_LIBCPP_ALWAYS_INLINE=\"\" -D_LIBCPP_EXTERN_TEMPLATE_INLINE_VISIBILITY=\"\"
echo "Compiling for iOS:"
if [ "$CLEAN" = YES ]; then
  rm -rf $IOS_BUILDDIR
fi
if [ ! -d $IOS_BUILDDIR ]; then
  mkdir $IOS_BUILDDIR
fi
# libc; impossible to configure
# compiler-rt; tries to set macosx-version-min
# openmp: requires compiler-rt and?
# 2023/03/09: try with compiler-rt, not openmp. 
# 2024/05: fails with openmp. Try without.
# Fails to compile, must use: -DLLVM_ENABLE_EH=OFF
# flang: issue with mlir-tblgen, also not cross-compiling.
# TODO: lldb.framework calls liblldb.18.1.5.dylib (make a framework) which calls libclang-cpp.dylib (ditto)
pushd $IOS_BUILDDIR
cmake -G Ninja \
-DLLVM_PARALLEL_LINK_JOBS="${LLVM_LINK_JOBS:-}" \
-DLLVM_LINK_LLVM_DYLIB=ON \
-DLLVM_TARGET_ARCH=AArch64 \
-DLLVM_TARGETS_TO_BUILD="AArch64;X86;WebAssembly" \
-DLLVM_ENABLE_PROJECTS='clang;lld;compiler-rt;lldb' \
-DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-darwin \
-DCMAKE_BUILD_TYPE=RelWithDebInfo \
-DLLVM_ENABLE_THREADS=OFF \
-DLLVM_ENABLE_TERMINFO=OFF \
-DLLVM_ENABLE_BACKTRACES=OFF \
-DLLVM_ENABLE_EH=OFF \
-DLLVM_ENABLE_RTTI=ON \
-DLLVM_ENABLE_LIBEDIT=OFF \
-DLLVM_ENABLE_ZSTD=OFF \
-DLLDB_INCLUDE_TESTS=OFF \
-DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
-DCMAKE_SYSTEM_NAME=Darwin \
-DLLDB_EXPORT_ALL_SYMBOLS=TRUE \
-DLLDB_ENABLE_LZMA=FALSE \
-DLLDB_ENABLE_PYTHON=FALSE \
-DLLDB_USE_SYSTEM_DEBUGSERVER=TRUE \
-DLLDB_TABLEGEN_EXE=${OSX_BUILDDIR}/bin/lldb-tblgen \
-DLLVM_TABLEGEN=${OSX_BUILDDIR}/bin/llvm-tblgen \
-DCLANG_TABLEGEN=${OSX_BUILDDIR}/bin/clang-tblgen \
-DCMAKE_OSX_SYSROOT=${IOS_SDKROOT} \
-DCMAKE_C_COMPILER=$(xcrun -f clang) \
-DCMAKE_CXX_COMPILER=$(xcrun -f clang++) \
-DCMAKE_LIBRARY_PATH=${OSX_BUILDDIR}/lib/ \
-DCMAKE_INCLUDE_PATH=${OSX_BUILDDIR}/include/ \
-DCOMPILER_RT_BUILD_BUILTINS=ON \
-DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
-DCOMPILER_RT_BUILD_MEMPROF=OFF \
-DCOMPILER_RT_BUILD_PROFILE=OFF \
-DCOMPILER_RT_BUILD_SANITIZERS=OFF \
-DCOMPILER_RT_BUILD_XRAY=OFF \
-DLIBOMP_LDFLAGS="-L lib/clang/18/lib/darwin -lclang_rt.cc_kext_ios" \
-DCMAKE_C_FLAGS="-arch arm64 -target arm64-apple-darwin19.6.0 -O2 -D_LIBCPP_STRING_H_HAS_CONST_OVERLOADS -DDONT_GET_PLUGIN_LOADER_OPTION -I${OSX_BUILDDIR}/include/ -I${OSX_BUILDDIR}/include/c++/v1/ -I${LLVM_SRCDIR} -miphoneos-version-min=14 -fwasm-exceptions" \
-DCMAKE_CXX_FLAGS="-arch arm64 -target arm64-apple-darwin19.6.0 -O2 -D_LIBCPP_STRING_H_HAS_CONST_OVERLOADS  -DDONT_GET_PLUGIN_LOADER_OPTION -I${OSX_BUILDDIR}/include/  -I${LLVM_SRCDIR} -miphoneos-version-min=14 " \
-DCMAKE_MODULE_LINKER_FLAGS="-nostdlib -F${LLVM_SRCDIR}/ios_system.xcframework/ios-arm64 -O2 -framework ios_system -lobjc -lc -lc++ -miphoneos-version-min=14 " \
-DCMAKE_SHARED_LINKER_FLAGS="-nostdlib -F${LLVM_SRCDIR}/ios_system.xcframework/ios-arm64 -O2 -framework ios_system -lobjc -lc -lc++ -miphoneos-version-min=14 " \
-DCMAKE_EXE_LINKER_FLAGS="-nostdlib -F${LLVM_SRCDIR}/ios_system.xcframework/ios-arm64 -O2 -framework ios_system -lobjc -lc -lc++ -miphoneos-version-min=14 -fwasm-exceptions " \
../llvm
ninja ${NINJA_JOBS:+-j"$NINJA_JOBS"} "${framework_targets[@]}" clang opt
# We could add X86 to target architectures, but that increases the app size too much
# Now build the static libraries for the executables:
# -stdlib=libc++: not required with OSX > Mavericks
# -nostdlib: so ios_system is linked *before* libc and libc++ 
# try with: -fvisibility=hidden -fvisibility-inlines-hidden in CFLAGS for the warning
# -L lib = crashes every time (self-reference).
# lli crashes, but only lli. When creating main() (before the first line)
rm -f lib/liblli.a
rm -f lib/libllc.a
# Xcode gets confused if a static and a dynamic library share the same name:
rm -f lib/libclang_tool.a
rm -f lib/libopt.a
ar -r lib/libclang_tool.a tools/clang/tools/driver/CMakeFiles/clang.dir/driver.cpp.o tools/clang/tools/driver/CMakeFiles/clang.dir/cc1_main.cpp.o tools/clang/tools/driver/CMakeFiles/clang.dir/cc1as_main.cpp.o tools/clang/tools/driver/CMakeFiles/clang.dir/cc1gen_reproducer_main.cpp.o  
ar -r lib/libopt.a  tools/opt/CMakeFiles/opt.dir/opt.cpp.o
# ar -r lib/libopt.a tools/opt/CMakeFiles/opt.dir/NewPMDriver.cpp.o tools/opt/CMakeFiles/opt.dir/opt.cpp.o
# No need to make static libraries for these:
# lli: tools/lli/CMakeFiles/lli.dir/lli.cpp.o 
# llvm-link: tools/llvm-link/CMakeFiles/llvm-link.dir/llvm-link.cpp.o
# llvm-nm:  tools/llvm-nm/CMakeFiles/llvm-nm.dir/llvm-nm.cpp.o
# llvm-ar:  tools/llvm-ar/CMakeFiles/llvm-ar.dir/llvm-ar.cpp.o
# llvm-dis:  tools/llvm-dis/CMakeFiles/llvm-dis.dir/llvm-dis.cpp.o
# llc: tools/llc/CMakeFiles/llc.dir/llc.cpp.o
# lld, wasm-ld, etc: done in Xcode.
rm -rf frameworks.xcodeproj
cp -r ../frameworks/frameworks.xcodeproj .
# And then build the frameworks from these static libraries:
# Somehow, -alltargets does not build all targets. 
xcodebuild -project frameworks.xcodeproj -target libLLVM -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target ar -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target clang -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target opt -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target nm -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target dis -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target link -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target lld -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target lli -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target llc -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target lldb -sdk iphoneos -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
# xcodebuild -project frameworks.xcodeproj -alltargets -sdk iphoneos -configuration Release -quiet
popd

fi

if [ "$SDK" != iphoneos ]; then
# Now, build for the simulator:
echo "Compiling for the simulator:"
if [ "$CLEAN" = YES ]; then
  rm -rf $SIM_BUILDDIR
fi
if [ ! -d $SIM_BUILDDIR ]; then
  mkdir $SIM_BUILDDIR
fi
pushd $SIM_BUILDDIR
cmake -G Ninja \
-DLLVM_PARALLEL_LINK_JOBS="${LLVM_LINK_JOBS:-}" \
-DLLVM_LINK_LLVM_DYLIB=ON \
-DLLVM_TARGET_ARCH=X86 \
-DLLVM_TARGETS_TO_BUILD="AArch64;X86;WebAssembly" \
-DLLVM_ENABLE_PROJECTS='clang;lld;compiler-rt;lldb' \
-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-darwin19.6.0 \
-DCMAKE_BUILD_TYPE=Release \
-DLLVM_ENABLE_THREADS=OFF \
-DLLVM_ENABLE_TERMINFO=OFF \
-DLLVM_ENABLE_BACKTRACES=OFF \
-DLLVM_ENABLE_EH=OFF \
-DLLVM_ENABLE_RTTI=ON \
-DLLDB_ENABLE_LZMA=FALSE \
-DLLDB_ENABLE_PYTHON=FALSE \
-DLLVM_ENABLE_ZSTD=OFF \
-DLLDB_INCLUDE_TESTS=OFF \
-DLLDB_EXPORT_ALL_SYMBOLS=TRUE \
-DLLDB_USE_SYSTEM_DEBUGSERVER=TRUE \
-DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
-DLLVM_ENABLE_LIBEDIT=OFF \
-DCMAKE_SYSTEM_NAME=Darwin \
-DLLDB_USE_SYSTEM_DEBUGSERVER=TRUE \
-DLLDB_TABLEGEN_EXE=${OSX_BUILDDIR}/bin/lldb-tblgen \
-DLLVM_TABLEGEN=${OSX_BUILDDIR}/bin/llvm-tblgen \
-DCLANG_TABLEGEN=${OSX_BUILDDIR}/bin/clang-tblgen \
-DCMAKE_OSX_SYSROOT=${SIM_SDKROOT} \
-DCMAKE_C_COMPILER=$(xcrun -f clang) \
-DCMAKE_CXX_COMPILER=$(xcrun -f clang++) \
-DCMAKE_LIBRARY_PATH=${OSX_BUILDDIR}/lib/ \
-DCMAKE_INCLUDE_PATH=${OSX_BUILDDIR}/include/ \
-DCOMPILER_RT_BUILD_BUILTINS=ON \
-DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
-DCOMPILER_RT_BUILD_MEMPROF=OFF \
-DCOMPILER_RT_BUILD_PROFILE=OFF \
-DCOMPILER_RT_BUILD_SANITIZERS=OFF \
-DCOMPILER_RT_BUILD_XRAY=OFF \
-DLIBOMP_LDFLAGS="-L lib/clang/18/lib/darwin -lclang_rt.cc_kext_ios" \
-DCMAKE_C_FLAGS="-target x86_64-apple-darwin19.6.0 -O2 -D_LIBCPP_STRING_H_HAS_CONST_OVERLOADS -DDONT_GET_PLUGIN_LOADER_OPTION -I${OSX_BUILDDIR}/include/ -I${OSX_BUILDDIR}/include/c++/v1/ -I${LLVM_SRCDIR} -mios-simulator-version-min=14.0  " \
-DCMAKE_CXX_FLAGS="-target x86_64-apple-darwin19.6.0 -O2 -D_LIBCPP_STRING_H_HAS_CONST_OVERLOADS  -DDONT_GET_PLUGIN_LOADER_OPTION -I${OSX_BUILDDIR}/include/  -I${LLVM_SRCDIR} -mios-simulator-version-min=14.0 " \
-DCMAKE_MODULE_LINKER_FLAGS="-nostdlib -F${LLVM_SRCDIR}/ios_system.xcframework/ios-arm64_x86_64-simulator -O2 -framework ios_system -lobjc -lc -lc++ -mios-simulator-version-min=14.0 " \
-DCMAKE_SHARED_LINKER_FLAGS="-nostdlib -F${LLVM_SRCDIR}/ios_system.xcframework/ios-arm64_x86_64-simulator -O2 -framework ios_system -lobjc -lc -lc++ -mios-simulator-version-min=14.0 " \
-DCMAKE_EXE_LINKER_FLAGS="-nostdlib -F${LLVM_SRCDIR}/ios_system.xcframework/ios-arm64_x86_64-simulator -O2 -framework ios_system -lobjc -lc -lc++ -mios-simulator-version-min=14.0 -fwasm-exceptions " \
../llvm
ninja ${NINJA_JOBS:+-j"$NINJA_JOBS"} "${framework_targets[@]}" clang opt
# We could add X86 to target architectures, but that increases the app size too much
# Now build the static libraries for the executables:
# -stdlib=libc++: not required with OSX > Mavericks
# -nostdlib: so ios_system is linked *before* libc and libc++ 
# try with: -fvisibility=hidden -fvisibility-inlines-hidden in CFLAGS for the warning
# -L lib = crashes every time (self-reference).
# lli crashes, but only lli. When creating main() (before the first line)
rm -f lib/liblli.a
rm -f lib/libllc.a
# Xcode gets confused if a static and a dynamic library share the same name:
rm -f lib/libclang_tool.a
rm -f lib/libopt.a
ar -r lib/libclang_tool.a tools/clang/tools/driver/CMakeFiles/clang.dir/driver.cpp.o tools/clang/tools/driver/CMakeFiles/clang.dir/cc1_main.cpp.o tools/clang/tools/driver/CMakeFiles/clang.dir/cc1as_main.cpp.o tools/clang/tools/driver/CMakeFiles/clang.dir/cc1gen_reproducer_main.cpp.o  
ar -r lib/libopt.a tools/opt/CMakeFiles/opt.dir/opt.cpp.o
# ar -r lib/libopt.a tools/opt/CMakeFiles/opt.dir/NewPMDriver.cpp.o tools/opt/CMakeFiles/opt.dir/opt.cpp.o
# No need to make static libraries for these:
# lli: tools/lli/CMakeFiles/lli.dir/lli.cpp.o 
# llvm-link: tools/llvm-link/CMakeFiles/llvm-link.dir/llvm-link.cpp.o
# llvm-nm:  tools/llvm-nm/CMakeFiles/llvm-nm.dir/llvm-nm.cpp.o
# llvm-ar:  tools/llvm-ar/CMakeFiles/llvm-ar.dir/llvm-ar.cpp.o
# llvm-dis:  tools/llvm-dis/CMakeFiles/llvm-dis.dir/llvm-dis.cpp.o
# llc: tools/llc/CMakeFiles/llc.dir/llc.cpp.o
# lld, wasm-ld, etc: done in Xcode.
rm -rf frameworks.xcodeproj
cp -r ../frameworks/frameworks.xcodeproj .
# And then build the frameworks from these static libraries:
# Somehow, -alltargets does not build all targets
xcodebuild -project frameworks.xcodeproj -target libLLVM -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target ar -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target clang -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target opt -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target nm -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target dis -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target link -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target lld -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target lli -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target llc -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
xcodebuild -project frameworks.xcodeproj -target lldb -sdk iphonesimulator -arch x86_64 -configuration Release -quiet CODE_SIGNING_ALLOWED=NO
popd

fi

[ "$SDK" = all ] || exit 0

# 6)
echo "Merging into xcframeworks:"

for framework in ar lld llc clang dis libLLVM link lli nm opt lldb
do
   rm -rf $framework.xcframework
   xcodebuild -create-xcframework -framework build-iphoneos/build/Release-iphoneos/$framework.framework -framework build-iphonesimulator/build/Release-iphonesimulator/$framework.framework -output $framework.xcframework
   # while we're at it, let's compute the checksum:
   rm -f $framework.xcframework.zip
   zip -rq $framework.xcframework.zip $framework.xcframework
   swift package compute-checksum $framework.xcframework.zip
done
