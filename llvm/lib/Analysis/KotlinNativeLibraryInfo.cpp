//===-- KotlinNativeLibraryInfo.cpp - Kotlin Native Library information ----==//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements the KotlinNativeLibraryInfo registry.
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/KotlinNativeLibraryInfo.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/raw_ostream.h"
#include <array>
#include <cstdio>
using namespace llvm;

// TEMPORARY diagnostic instrumentation -- remove once the registry is
// confirmed working end-to-end.
//
// Deliberately NOT using llvm::errs()/outs(): when this pass runs inside the
// Kotlin/Native compiler driver (as opposed to the standalone `opt` tool),
// Kotlin appears to capture/suppress whatever LLVM writes to its normal
// diagnostic streams, so nothing from errs() ever becomes visible even when
// the code path genuinely runs. Writing straight to a fixed file with plain
// C stdio sidesteps that entirely -- it doesn't go through any LLVM stream
// object Kotlin could be intercepting, and doesn't depend on process
// stdout/stderr being forwarded anywhere.
static void knliTraceImpl(const std::string &Msg) {
  if (FILE *F = std::fopen("/tmp/knli-debug.log", "a")) {
    std::fprintf(F, "[KNLI-DEBUG] %s\n", Msg.c_str());
    std::fclose(F);
  }
}
#define KNLI_TRACE(X)                                                        \
  do {                                                                       \
    std::string KnliTraceMsg;                                                \
    raw_string_ostream KnliTraceOS(KnliTraceMsg);                            \
    KnliTraceOS << X;                                                        \
    knliTraceImpl(KnliTraceMsg);                                             \
  } while (0)

static StringLiteral const KotlinNativeLibFuncNames[NumKotlinNativeLibFuncs] =
    {
#define KNLI_DEFINE_STRING
#include "llvm/Analysis/KotlinNativeLibraryInfo.def"
};

// Recognized types of registry function arguments and return types. This
// mirrors (a subset of) TargetLibraryInfo.cpp's FuncArgTypeID, but the match
// below is deliberately looser: the real safety net for this registry is the
// exact-name match against a small, hand-verified list, not a strict
// signature check.
enum KotlinNativeFuncArgTypeID : char {
  Void = 0, // Must be zero.
  Bool,     // A C++ bool parameter: Clang's ABI lowering represents these as
            // i1 (with a zeroext attribute) in a function's parameter list,
            // not i8 (i8 does show up for bool in other contexts, e.g. struct
            // fields or arrays, just not here).
  Int32,
  Long,     // size_t-like; 32 or 64 bits.
  Ptr,      // Any pointer type.
  Struct,   // Any struct type, or the array-coerced form Clang's ABI
            // lowering produces for small by-value aggregates (e.g. the
            // [2 x i64] it emits for std_support::span<char> by value).
  Ellip,    // The ellipsis (...).
  Any,      // Matches any type, including void; used for return types that
            // may be optimized away (e.g. dead-return-value elimination).
};

typedef std::array<KotlinNativeFuncArgTypeID, 8> KotlinNativeFuncProtoTy;

static const KotlinNativeFuncProtoTy KotlinNativeSignatures[] = {
#define KNLI_DEFINE_SIG
#include "llvm/Analysis/KotlinNativeLibraryInfo.def"
};

static_assert(sizeof KotlinNativeSignatures / sizeof *KotlinNativeSignatures ==
                  NumKotlinNativeLibFuncs,
              "Missing Kotlin/Native library function signatures");

static bool matchType(KotlinNativeFuncArgTypeID ArgTy, const Type *Ty) {
  switch (ArgTy) {
  case Void:
    return Ty->isVoidTy();
  case Bool:
    return Ty->isIntegerTy(1) || Ty->isIntegerTy(8);
  case Int32:
    return Ty->isIntegerTy(32);
  case Long:
    return Ty->isIntegerTy() && Ty->getPrimitiveSizeInBits() >= 32;
  case Ptr:
    return Ty->isPointerTy();
  case Struct:
    return Ty->isStructTy() || Ty->isArrayTy();
  case Any:
    return true;
  default:
    break;
  }

  llvm_unreachable("Invalid type");
}

static bool isValidProtoForKotlinNativeLibFunc(const FunctionType &FTy,
                                               KotlinNativeLibFunc F) {
  unsigned NumParams = FTy.getNumParams();

  unsigned Idx = 0;
  Type *Ty = FTy.getReturnType();
  const auto &ProtoTypes = KotlinNativeSignatures[F];
  KNLI_TRACE("  isValidProtoForKotlinNativeLibFunc: NumParams=" << NumParams
             << " isVarArg=" << FTy.isFunctionVarArg());
  for (auto TyID : ProtoTypes) {
    {
      std::string TyStr;
      raw_string_ostream OS(TyStr);
      if (Ty) Ty->print(OS); else OS << "<null>";
      KNLI_TRACE("    Idx=" << Idx << " TyID=" << (int)TyID << " actualTy=" << TyStr);
    }

    if (Idx && TyID == Void)
      break;

    if (TyID == Ellip) {
      assert(Idx == ProtoTypes.size() - 1 || ProtoTypes[Idx + 1] == Void);
      bool R = FTy.isFunctionVarArg();
      KNLI_TRACE("    -> Ellip reached, isFunctionVarArg=" << R);
      return R;
    }

    if (!Ty || !matchType(TyID, Ty)) {
      KNLI_TRACE("    -> matchType FAILED at Idx=" << Idx);
      return false;
    }

    if (Idx == NumParams) {
      Ty = nullptr;
      ++Idx;
      continue;
    }

    Ty = FTy.getParamType(Idx++);
  }

  bool R = Idx == NumParams + 1 && !FTy.isFunctionVarArg();
  KNLI_TRACE("    -> loop ended without Ellip, result=" << R);
  return R;
}

static DenseMap<StringRef, KotlinNativeLibFunc> buildIndexMap() {
  DenseMap<StringRef, KotlinNativeLibFunc> Indices;
  Indices.reserve(NumKotlinNativeLibFuncs);
  unsigned Idx = 0;
  for (const auto &Name : KotlinNativeLibFuncNames)
    Indices[Name] = static_cast<KotlinNativeLibFunc>(Idx++);
  return Indices;
}

bool llvm::getKotlinNativeLibFunc(StringRef FuncName, KotlinNativeLibFunc &F) {
  if (FuncName.empty())
    return false;

  static const DenseMap<StringRef, KotlinNativeLibFunc> Indices =
      buildIndexMap();

  if (auto Loc = Indices.find(FuncName); Loc != Indices.end()) {
    F = Loc->second;
    return true;
  }
  return false;
}

bool llvm::getKotlinNativeLibFunc(const Function &FDecl,
                                  KotlinNativeLibFunc &F) {
  if (FDecl.isIntrinsic())
    return false;

  if (!getKotlinNativeLibFunc(FDecl.getName(), F)) {
    KNLI_TRACE("getKotlinNativeLibFunc(Function): name '" << FDecl.getName()
               << "' not in registry");
    return false;
  }

  bool R = isValidProtoForKotlinNativeLibFunc(*FDecl.getFunctionType(), F);
  KNLI_TRACE("getKotlinNativeLibFunc(Function): name '" << FDecl.getName()
             << "' IS in registry (enum=" << (unsigned)F << "), proto check -> "
             << R);
  return R;
}

bool llvm::getKotlinNativeLibFunc(const CallBase &CB, KotlinNativeLibFunc &F) {
  const Function *Callee = CB.getCalledFunction();
  KNLI_TRACE("getKotlinNativeLibFunc(CallBase): isNoBuiltin=" << CB.isNoBuiltin()
             << " callee=" << (Callee ? Callee->getName() : "<indirect/null>"));
  return !CB.isNoBuiltin() && CB.getCalledFunction() &&
         getKotlinNativeLibFunc(*CB.getCalledFunction(), F);
}
