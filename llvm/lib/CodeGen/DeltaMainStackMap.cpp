//===- DeltaMainStackMap.cpp ----------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/CodeGen/DeltaMainStackMap.h"
#include "llvm/MC/MCStreamer.h"
#include "llvm/Support/ErrorHandling.h"

using namespace llvm;
using namespace llvm::deltamain;

void Delta::emit(MCStreamer &OS, bool EmitRegisters) const {
  if (EmitRegisters) {
    OS.emitULEB128BitVector(Regs);
  } else if (!Regs.empty()) {
    report_fatal_error("delta-main: register bit vector is non-empty but "
                       "register-in-stackmap support is disabled");
  }

  OS.emitULEB128BitVector(StackSlots);

  OS.emitULEB128IntValue(DerivedSlots.size());
  for (const auto &Derived : DerivedSlots) {
    OS.emitSLEB128IntValue(Derived.first);
    OS.emitSLEB128IntValue(Derived.second);
  }
}
