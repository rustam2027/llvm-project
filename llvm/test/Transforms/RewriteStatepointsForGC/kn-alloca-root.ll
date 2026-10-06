; RUN: opt < %s -passes=rewrite-statepoints-for-gc -S | FileCheck %s

%T = type { ptr addrspace(1), i64 }

declare void @foo()
declare void @use(ptr addrspace(1))

define void @test() gc "statepoint-example" {
; CHECK-LABEL: @test
; CHECK:       "gc-live"(ptr addrspace(1) %obj)
; CHECK:       [[R:%.*]] = call coldcc ptr addrspace(1) @llvm.experimental.gc.relocate.p1
; CHECK:       call void @use(ptr addrspace(1) [[R]])
  %obj = alloca %T, align 8, addrspace(1)
  call void @foo()
  call void @use(ptr addrspace(1) %obj)
  ret void
}
