; RUN: opt < %s -passes=rewrite-statepoints-for-gc -S | FileCheck %s

%T = type { ptr addrspace(1), i64 }

declare void @foo()
declare void @use(ptr addrspace(1))

; A static alloca is its own base and is never relocated: it stays in gc-live
; and its users keep the alloca.
; CHECK-LABEL: @test(
; CHECK-NOT:   gc.relocate
; CHECK:       "gc-live"(ptr addrspace(1) %obj)
; CHECK:       @use, i32 1, i32 0, ptr addrspace(1) %obj
; CHECK:       "gc-live"(ptr addrspace(1) %obj)
; CHECK-NOT:   gc.relocate
define void @test() gc "statepoint-example" {
  %obj = alloca %T, align 8, addrspace(1)
  call void @foo()
  call void @use(ptr addrspace(1) %obj)
  ret void
}

; A pointer into the object is a use of the object: it is not live, relocated
; or rematerialised on its own.
; CHECK-LABEL: @derived(
; CHECK-NOT:   gc.relocate
; CHECK-NOT:   .remat
; CHECK:       "gc-live"(ptr addrspace(1) %obj)
; CHECK:       @use, i32 1, i32 0, ptr addrspace(1) %f,
define void @derived() gc "statepoint-example" {
  %obj = alloca %T, align 8, addrspace(1)
  %f = getelementptr %T, ptr addrspace(1) %obj, i32 0, i32 1
  call void @foo()
  call void @use(ptr addrspace(1) %f)
  ret void
}
