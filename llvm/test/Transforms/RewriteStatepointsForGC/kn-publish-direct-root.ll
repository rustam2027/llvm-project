; RUN: opt < %s -passes=rewrite-statepoints-for-gc -S | FileCheck %s
; RUN: opt < %s -passes=rewrite-statepoints-for-gc -spp-print-base-pointers -disable-output 2>&1 | FileCheck %s --check-prefix=BASE

%Object = type { i64, ptr addrspace(1) }

declare void @foo()
declare void @use(ptr addrspace(1))
declare ptr @get_opaque()

; A stack object published via kn.publish is rooted by the alloca itself: the
; publish result is the only GC-visible reference, so the alloca is the base
; and is carried in gc-live as the Direct stack slot.
; CHECK-LABEL: @test(
; CHECK:       [ "gc-live"(ptr addrspace(1) %p, ptr %slot)
; BASE-LABEL: Base Pairs (w/o Relocation):
; BASE:       derived %p base %slot
; BASE:       derived %slot base %slot
define void @test(ptr addrspace(1) %ti) gc "kotlin-native" {
  %slot = alloca %Object, align 8
  store ptr addrspace(1) %ti, ptr %slot
  %p = call ptr addrspace(1) @llvm.kn.publish(ptr %slot)
  call void @foo()
  call void @use(ptr addrspace(1) %p)
  ret void
}

; A pointer derived from the publish result is recomputed from the alloca,
; which stays the base.
; CHECK-LABEL: @derived(
; CHECK:       [ "gc-live"(ptr addrspace(1) %f, ptr %slot)
; BASE:       derived %f base %slot
define void @derived(ptr addrspace(1) %ti) gc "kotlin-native" {
  %slot = alloca %Object, align 8
  store ptr addrspace(1) %ti, ptr %slot
  %p = call ptr addrspace(1) @llvm.kn.publish(ptr %slot)
  %f = getelementptr %Object, ptr addrspace(1) %p, i32 0, i32 1
  call void @foo()
  call void @use(ptr addrspace(1) %f)
  ret void
}

; Publish through a zero-offset GEP and a cast still finds the alloca.
; CHECK-LABEL: @through_casts(
; CHECK:       [ "gc-live"(ptr addrspace(1) %p, ptr %slot)
; BASE:       derived %p base %slot
define void @through_casts(ptr addrspace(1) %ti) gc "kotlin-native" {
  %slot = alloca %Object, align 8
  store ptr addrspace(1) %ti, ptr %slot
  %g = getelementptr %Object, ptr %slot, i32 0
  %c = bitcast ptr %g to ptr
  %p = call ptr addrspace(1) @llvm.kn.publish(ptr %c)
  call void @foo()
  call void @use(ptr addrspace(1) %p)
  ret void
}

; Not a stack object: the publish result remains its own base, like any other
; call result, and is reported as a regular (indirect) root.
; CHECK-LABEL: @bridged(
; CHECK-NOT:   [ "gc-live"(ptr %raw
; CHECK:       [ "gc-live"(ptr addrspace(1) %p)
; BASE:       derived %p base %p
define void @bridged() gc "kotlin-native" {
  %raw = call ptr @get_opaque()
  %p = call ptr addrspace(1) @llvm.kn.publish(ptr %raw)
  call void @foo()
  call void @use(ptr addrspace(1) %p)
  ret void
}
