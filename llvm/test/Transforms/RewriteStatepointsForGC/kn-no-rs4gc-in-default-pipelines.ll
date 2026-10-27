; RUN: opt < %s -passes='default<O0>' -S | FileCheck %s
; RUN: opt < %s -passes='default<O2>' -S | FileCheck %s

; RS4GC runs once, as the last phase of the compiler (kotlin-remove-sp has to see
; plain calls before that), so no default pipeline contains it.

declare void @foo()

; CHECK-LABEL: @f(
; CHECK-NOT:   gc.statepoint
define void @f(ptr addrspace(1) %a) gc "kotlin-native" {
  call void @foo()
  ret void
}
