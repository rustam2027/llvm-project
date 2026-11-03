; RUN: opt < %s -passes='default<O3>,rewrite-statepoints-for-gc' -S | FileCheck %s

%Obj = type { i64, ptr addrspace(1), ptr addrspace(1) }

declare void @P()
declare void @use(ptr addrspace(1))
declare void @llvm.lifetime.start.p1(i64 immarg, ptr addrspace(1) nocapture)
declare void @llvm.memset.p1.i32(ptr addrspace(1) nocapture writeonly, i8, i32, i1 immarg)

; The inliner moves the alloca to the caller entry, the init stays at the inline
; site. Statepoints before the birth must not see the object, the one after it must,
; the init must stay before that statepoint, and the object must stay one alloca
; (the barrier is what keeps SROA from splitting it).
; CHECK-LABEL: @caller(
; CHECK:       %o.i = alloca %Obj
; CHECK-NOT:   alloca
; CHECK-NOT:   "gc-live"({{.*}}%o.i
; CHECK:       lifetime.start
; CHECK:       memset
; CHECK:       asm sideeffect
; CHECK:       "gc-live"(ptr addrspace(1) %o.i,
define internal void @callee(ptr addrspace(1) %x, ptr addrspace(1) %kc) gc "kotlin-native" {
  %o = alloca %Obj, align 8, addrspace(1)
  call void @P()
  call void @llvm.lifetime.start.p1(i64 24, ptr addrspace(1) %o)
  call void @llvm.memset.p1.i32(ptr addrspace(1) %o, i8 0, i32 24, i1 false)
  store ptr addrspace(1) %kc, ptr addrspace(1) %o
  call void asm sideeffect "", "r,~{memory}"(ptr addrspace(1) %o)
  call void @P()
  %f1 = getelementptr %Obj, ptr addrspace(1) %o, i32 0, i32 1
  store ptr addrspace(1) %x, ptr addrspace(1) %f1
  call void @use(ptr addrspace(1) %o)
  ret void
}

define void @caller(ptr addrspace(1) %x, ptr addrspace(1) %kc) gc "kotlin-native" {
  call void @P()
  call void @callee(ptr addrspace(1) %x, ptr addrspace(1) %kc)
  ret void
}
