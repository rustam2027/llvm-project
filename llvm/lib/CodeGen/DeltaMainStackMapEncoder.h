//===- DeltaMainStackMapEncoder.h - build/emit delta-main maps -*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Converts a StackMaps object's recorded per-callsite location data into the
// delta-main::EncodedStackMap representation (see
// llvm/CodeGen/DeltaMainStackMap.h) and serializes it. Used by
// KotlinNativeGCPrinter, which is the only intended caller: the encoder
// itself does not touch AsmPrinter, the "kotlin-native" GCStrategy, or the
// StackMaps section-emission machinery.
//
// NOTE: this is an implementation-detail header (lives in lib/, not
// include/) analogous to other CodeGen-internal helper headers such as
// llvm/lib/CodeGen/SafeStackLayout.h.
//
// Current limitations of this initial port (see class comment below):
//  - AArch64 only.
//  - Register-liveness tracking (EmitRegisters=true) is not wired up to a
//    location source yet; StackMaps does not currently record which
//    callee-saved registers are live at a callsite the way it records
//    stack slots. Passing EmitRegisters=true will report_fatal_error as
//    soon as a register-typed GC root is encountered.
//  - No lazy/offset-section support: every function's delta-main record is
//    emitted unconditionally into the stackmap section, mirroring how the
//    default StackMaps::serializeToStackMapSection() behaves today.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_CODEGEN_DELTAMAINSTACKMAPENCODER_H
#define LLVM_LIB_CODEGEN_DELTAMAINSTACKMAPENCODER_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/BitVector.h"
#include "llvm/CodeGen/DeltaMainStackMap.h"
#include "llvm/CodeGen/StackMaps.h"
#include <map>
#include <set>

namespace llvm {

class MCStreamer;

/// Builds a deltamain::EncodedStackMap from a StackMaps object and
/// serializes it to the delta-main wire format.
///
/// This class is AArch64-only: enumerate()'s register renumbering is not
/// target-independent (see its doc comment). Callers must verify the
/// target triple before use; the encoder itself does not check it, since
/// doing so requires a Triple/TargetMachine that KotlinNativeGCPrinter
/// already has available via AsmPrinter.
class DeltaMainStackMapEncoder {
public:
  /// \param EmitRegisters whether to encode callee-saved-register liveness
  /// in addition to stack-slot liveness. See the file comment: this is not
  /// yet backed by real register-liveness data and will fail loudly if a
  /// register-typed root is actually encountered while enabled.
  explicit DeltaMainStackMapEncoder(int DeltaMainVersion, bool EmitRegisters, bool LazyEnabled)
      : DeltaMainVersion(DeltaMainVersion), EmitRegisters(EmitRegisters), LazyEnabled(LazyEnabled) {}

  /// Build the delta-main-encoded form of every function in \p SM that has
  /// at least one recorded, GC-relevant call site.
  deltamain::EncodedStackMap build(StackMaps &SM) const;

  /// Serialize \p Map to \p OS. Wire format, per function:
  ///   i32   offset of the function's entry point from "__LLVM_StackMaps"
  ///   sleb  Func.BaseOffset
  ///   uleb  Func.StackSize
  ///   ...   Func.Base (see Delta::emit)
  ///   uleb  Func.PcToDelta.size()
  ///   ...   for each entry: uleb-encoded PC offset, uleb-encoded delta index
  ///   ...   each unique Delta in Func.Deltas, in insertion order (see
  ///         Delta::emit)
  void emit(MCStreamer &OS, const deltamain::EncodedStackMap &Map) const;

private:
  int DeltaMainVersion;
  bool EmitRegisters;
  bool LazyEnabled;

  using BaseToDerivedMap =
      std::map<deltamain::Location, std::set<deltamain::Location>>;

  /// Recover the base/derived GC-pointer pairs, and the alloca roots, that
  /// StackMaps::parseStatepointOpers flattened into \p CSI.Locations. A key
  /// with an empty value set denotes a location that is itself a root with
  /// no separately-live derived pointer (either a lone base pointer, or an
  /// alloca root).
  BaseToDerivedMap collectBaseToDerived(const StackMaps::CallsiteInfo &CSI) const;

  /// Classify every (base, derived) pair from \p Base2Derived into
  /// \p State's Registers/StackSlots/DerivedSlots.
  void populateState(deltamain::State &State,
                     const BaseToDerivedMap &Base2Derived) const;

  /// Build the (not yet delta-compressed) per-callsite State list for one
  /// function. \p StartIdx is the index of this function's first record in
  /// \p CSInfos (StackMaps records callsites for all functions in one flat
  /// list, in the order functions were first seen).
  deltamain::FunctionState
  buildFunctionState(const MCSymbol *Symbol,
                     const StackMaps::FunctionInfo &FnInfo,
                     const StackMaps::CallsiteInfoList &CSInfos,
                     unsigned StartIdx) const;

  /// Delta-compress \p Func's States against its first recorded State and
  /// deduplicate the results.
  deltamain::FuncDesc buildFuncDesc(const deltamain::FunctionState &Func) const;

  /// Encode a single State as a Delta against an implicit all-zero state
  /// (i.e. its own full live-location set).
  deltamain::Delta computeDelta(const deltamain::State &State) const;

  /// Encode the symmetric difference between two States as a Delta.
  deltamain::Delta computeDelta(const deltamain::State &Base,
                                const deltamain::State &Other) const;

  /// Build a bit vector with bit enumerate(Loc) set for every Loc in
  /// \p Locs.
  BitVector getLocationMask(ArrayRef<deltamain::Location> Locs) const;

  /// Maps a Location to a dense, non-negative bit-vector index.
  ///
  /// For AArch64 callee-saved registers (x19-x28), remaps x19-x27 to 0-8
  /// (so the 9 general-purpose callee-saved registers pack densely at the
  /// start of the register bit vector) and leaves x28 and registers below
  /// x19 shifted to keep the mapping a bijection. This numbering is
  /// AArch64-specific; see the class comment.
  int64_t enumerate(const deltamain::Location &Loc) const;

  /// Like enumerate(), but returns a value that also encodes whether \p Loc
  /// is a stack slot or a register, for use as a DerivedSlots key/value:
  /// stack slots map to negative values (-enumerate(Loc) - 1), registers to
  /// their non-negative enumerate(Loc).
  int64_t signedEnumerate(const deltamain::Location &Loc) const;
};

} // end namespace llvm

#endif // LLVM_LIB_CODEGEN_DELTAMAINSTACKMAPENCODER_H
