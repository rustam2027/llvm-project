; RUN: opt < %s -passes=instcombine -S | FileCheck %s

declare void @foo()
declare void @use(ptr addrspace(1))
declare token @llvm.experimental.gc.statepoint.p0(i64, i32, ptr, i32, i32, ...)

; CHECK-LABEL: @no_gc_live(
; CHECK: call token {{.*}}@llvm.experimental.gc.statepoint
define void @no_gc_live() gc "kotlin-native" {
  %t = call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0(i64 0, i32 0, ptr elementtype(void ()) @foo, i32 0, i32 0, i32 0, i32 0)
  ret void
}

; A static alloca has no gc.relocate and must stay in gc-live.
; CHECK-LABEL: @static_alloca_kept(
; CHECK: "gc-live"(ptr addrspace(1) %o)
define void @static_alloca_kept() gc "kotlin-native" {
  %o = alloca i64, addrspace(1)
  %t = call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0(i64 0, i32 0, ptr elementtype(void ()) @foo, i32 0, i32 0, i32 0, i32 0) ["gc-live"(ptr addrspace(1) %o)]
  call void @use(ptr addrspace(1) %o)
  ret void
}

; A dynamic alloca is not a root and is dropped like any value without a relocate.
; CHECK-LABEL: @dynamic_alloca_dropped(
; CHECK: "gc-live"()
define void @dynamic_alloca_dropped(i32 %n) gc "kotlin-native" {
  %o = alloca i64, i32 %n, addrspace(1)
  %t = call token (i64, i32, ptr, i32, i32, ...) @llvm.experimental.gc.statepoint.p0(i64 0, i32 0, ptr elementtype(void ()) @foo, i32 0, i32 0, i32 0, i32 0) ["gc-live"(ptr addrspace(1) %o)]
  call void @use(ptr addrspace(1) %o)
  ret void
}
