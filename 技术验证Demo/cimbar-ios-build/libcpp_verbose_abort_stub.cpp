// libc++ hardening abort 桩 — 见 build-cimbar-ios.sh 的 "stub" 步骤说明:
// OpenCV 内置 kleidicv 以新 toolchain 编译, 引用了 iOS17+ 系统 libc++ 才导出的
// std::__1::__libcpp_verbose_abort (mangled: _ZNSt3__122__libcpp_verbose_abortEPKcz),
// 部署目标 13.0 的真机上 dyld 找不到该符号直接启动崩溃。
// 该函数只在 libc++ hardening 断言失败时被调用(正常生产路径永远不触发),
// 自带定义打进 .a 后链接器绑定到本桩, 不再依赖系统符号。
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

namespace std {
inline namespace __1 {

__attribute__((visibility("default")))
__attribute__((noreturn))
void __libcpp_verbose_abort(char const* format, ...) {
  va_list args;
  va_start(args, format);
  fprintf(stderr, "libc++ assertion: ");
  vfprintf(stderr, format, args);
  fprintf(stderr, "\n");
  va_end(args);
  abort();
}

}  // namespace __1
}  // namespace std
