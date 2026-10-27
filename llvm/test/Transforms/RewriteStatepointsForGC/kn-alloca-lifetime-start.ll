; RUN: opt < %s -passes=rewrite-statepoints-for-gc -S | FileCheck %s

%T = type { ptr addrspace(1), i64 }

declare void @foo()
declare void @use(ptr addrspace(1))
declare void @llvm.lifetime.start.p1(i64 immarg, ptr addrspace(1) nocapture)

; The alloca is not live before lifetime.start, even though it is used after it.
; CHECK-LABEL: @before_start(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0){{$}}
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %obj) ]
define void @before_start() gc "kotlin-native" {
  %obj = alloca %T, align 8, addrspace(1)
  call void @foo()
  call void @llvm.lifetime.start.p1(i64 16, ptr addrspace(1) %obj)
  store i64 0, ptr addrspace(1) %obj
  call void @foo()
  call void @use(ptr addrspace(1) %obj)
  ret void
}

; Every iteration starts a new lifetime: the call before the marker does not see the object.
; CHECK-LABEL: @loop(
; CHECK:       loop:
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0){{$}}
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %obj) ]
define void @loop(i1 %c) gc "kotlin-native" {
entry:
  %obj = alloca %T, align 8, addrspace(1)
  br label %loop

loop:
  call void @foo()
  call void @llvm.lifetime.start.p1(i64 16, ptr addrspace(1) %obj)
  store i64 0, ptr addrspace(1) %obj
  call void @foo()
  call void @use(ptr addrspace(1) %obj)
  br i1 %c, label %loop, label %exit

exit:
  ret void
}

; A use before the marker keeps the object live up to it.
; CHECK-LABEL: @use_then_start(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %obj) ]
define void @use_then_start() gc "kotlin-native" {
  %obj = alloca %T, align 8, addrspace(1)
  call void @foo()
  call void @use(ptr addrspace(1) %obj)
  call void @llvm.lifetime.start.p1(i64 16, ptr addrspace(1) %obj)
  ret void
}

; Without a marker the alloca is live from the entry to its last use.
; CHECK-LABEL: @no_marker(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %obj) ]
define void @no_marker() gc "kotlin-native" {
  %obj = alloca %T, align 8, addrspace(1)
  call void @foo()
  call void @use(ptr addrspace(1) %obj)
  ret void
}

; A pointer into the object defined before the marker (the optimizer hoists such
; GEPs out of loops) is a use of the object after the marker only.
; CHECK-LABEL: @hoisted_gep(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0){{$}}
; CHECK:       loop:
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0){{$}}
; CHECK:       lifetime.start
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %obj) ]
define void @hoisted_gep(i1 %c) gc "kotlin-native" {
entry:
  %obj = alloca %T, align 8, addrspace(1)
  call void @foo()
  %f = getelementptr %T, ptr addrspace(1) %obj, i32 0, i32 1
  br label %loop

loop:
  call void @foo()
  call void @llvm.lifetime.start.p1(i64 16, ptr addrspace(1) %obj)
  store i64 0, ptr addrspace(1) %f
  call void @foo()
  store i64 1, ptr addrspace(1) %f
  br i1 %c, label %loop, label %exit

exit:
  ret void
}
