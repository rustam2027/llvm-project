; RUN: opt < %s -passes=rewrite-statepoints-for-gc -S | FileCheck %s

declare void @foo()
declare void @use(ptr addrspace(1))
declare ptr addrspace(1) @get()

; A local variable that stays in memory is a root while it holds a value that is
; read later: a store defines the slot, a load uses it.
; CHECK-LABEL: @store_load(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %a) ]
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
; CHECK-NOT:   (%s,
define void @store_load(ptr addrspace(1) %a) gc "kotlin-native" {
  %s = alloca ptr addrspace(1), align 8
  call void @foo()
  store ptr addrspace(1) %a, ptr %s
  call void @foo()
  %v = load ptr addrspace(1), ptr %s
  call void @use(ptr addrspace(1) %v)
  ret void
}

; Before the first store the slot holds nothing: it is not reported.
; CHECK-LABEL: @before_store(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0){{$}}
; CHECK:       @get
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
define void @before_store() gc "kotlin-native" {
  %s = alloca ptr addrspace(1), align 8
  call void @foo()
  %p = call ptr addrspace(1) @get()
  store ptr addrspace(1) %p, ptr %s
  call void @foo()
  %v = load ptr addrspace(1), ptr %s
  call void @use(ptr addrspace(1) %v)
  ret void
}

; A later store ends the live range of the previous value: between the stores the
; slot is not a root, only the value that is about to be stored.
; CHECK-LABEL: @overwritten(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %b) ]
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
define void @overwritten(ptr addrspace(1) %a, ptr addrspace(1) %b) gc "kotlin-native" {
  %s = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %a, ptr %s
  call void @foo()
  store ptr addrspace(1) %b, ptr %s
  call void @foo()
  %v = load ptr addrspace(1), ptr %s
  call void @use(ptr addrspace(1) %v)
  ret void
}

; Variables in a loop: the slot is live around the back edge.
; CHECK-LABEL: @loop(
; CHECK:       loop:
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
define void @loop(i1 %c, ptr addrspace(1) %a) gc "kotlin-native" {
entry:
  %s = alloca ptr addrspace(1), align 8
  store ptr addrspace(1) %a, ptr %s
  br label %loop

loop:
  call void @foo()
  %v = load ptr addrspace(1), ptr %s
  call void @use(ptr addrspace(1) %v)
  br i1 %c, label %loop, label %exit

exit:
  ret void
}
