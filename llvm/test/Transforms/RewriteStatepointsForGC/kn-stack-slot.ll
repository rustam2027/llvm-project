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

; A store through a zero-offset GEP of the slot defines the slot like a direct
; store: the overwritten value stops being a root before it, the slot becomes
; one where its content is read later.
; CHECK-LABEL: @gep_store_kill(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %b) ]
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
define void @gep_store_kill(ptr addrspace(1) %a, ptr addrspace(1) %b) gc "kotlin-native" {
  %s = alloca ptr addrspace(1), align 8
  %slot.addr = getelementptr ptr addrspace(1), ptr %s, i64 0
  store ptr addrspace(1) %a, ptr %s
  call void @foo()
  store ptr addrspace(1) %b, ptr %slot.addr
  call void @foo()
  %v = load ptr addrspace(1), ptr %s
  call void @use(ptr addrspace(1) %v)
  ret void
}

; The same through a cast of the slot address.
; CHECK-LABEL: @cast_store_kill(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr addrspace(1) %b) ]
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
define void @cast_store_kill(ptr addrspace(1) %a, ptr addrspace(1) %b) gc "kotlin-native" {
  %s = alloca ptr addrspace(1), align 8
  %slot.cast = addrspacecast ptr %s to ptr addrspace(1)
  store ptr addrspace(1) %a, ptr %s
  call void @foo()
  store ptr addrspace(1) %b, ptr addrspace(1) %slot.cast
  call void @foo()
  %v = load ptr addrspace(1), ptr %s
  call void @use(ptr addrspace(1) %v)
  ret void
}

; The only store to the slot goes through the GEP: the slot is not a root
; before the first store (on the first loop iteration it holds garbage) and
; becomes one where the stored content is read.
; CHECK-LABEL: @gep_store_loop(
; CHECK:       loop:
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0){{$}}
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
define void @gep_store_loop(i1 %c) gc "kotlin-native" {
entry:
  %s = alloca ptr addrspace(1), align 8
  %slot.addr = getelementptr ptr addrspace(1), ptr %s, i64 0
  br label %loop

loop:
  call void @foo()
  store ptr addrspace(1) null, ptr %slot.addr
  call void @foo()
  %v = load ptr addrspace(1), ptr %s
  call void @use(ptr addrspace(1) %v)
  br i1 %c, label %loop, label %exit

exit:
  ret void
}

; A read through the GEP uses the slot: the slot is a root at the statepoint
; between the store and the read, carried by the slot, not by the stored value.
; CHECK-LABEL: @gep_load(
; CHECK:       @foo, i32 0, i32 0, i32 0, i32 0) [ "gc-live"(ptr %s) ]
define void @gep_load(ptr addrspace(1) %a) gc "kotlin-native" {
  %s = alloca ptr addrspace(1), align 8
  %slot.addr = getelementptr ptr addrspace(1), ptr %s, i64 0
  store ptr addrspace(1) %a, ptr %slot.addr
  call void @foo()
  %v = load ptr addrspace(1), ptr %slot.addr
  call void @use(ptr addrspace(1) %v)
  ret void
}
