//===-- ExternalFunctions.cpp - Implement External Functions --------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
//  This file contains both code to deal with invoking "external" functions, but
//  also contains code that implements "exported" external functions.
//
//  There are currently two mechanisms for handling external functions in the
//  Interpreter.  The first is to implement lle_* wrapper functions that are
//  specific to well-known library functions which manually translate the
//  arguments from GenericValues and make the call.  If such a wrapper does
//  not exist, and libffi is available, then the Interpreter will attempt to
//  invoke the function using libffi, after finding its address.
//
//===----------------------------------------------------------------------===//

#include "Interpreter.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Config/config.h" // Detect libffi
#include "llvm/ExecutionEngine/GenericValue.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/DynamicLibrary.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/Mutex.h"
#include "llvm/Support/raw_ostream.h"
#include <cassert>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#ifdef HAVE_FFI_CALL
#ifdef HAVE_FFI_H
#include <ffi.h>
#define USE_LIBFFI
#elif HAVE_FFI_FFI_H
#include <ffi/ffi.h>
#define USE_LIBFFI
#endif
#endif

#ifdef __APPLE__
#include <TargetConditionals.h>
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
#include <CoreFoundation/CoreFoundation.h>
#include <objc/objc.h>
#include <objc/message.h>
#include "ios_error.h"
#include <fcntl.h>
#endif
#endif

using namespace llvm;

namespace {

typedef GenericValue (*ExFunc)(FunctionType *, ArrayRef<GenericValue>);
typedef void (*RawFunc)();

struct Functions {
  sys::Mutex Lock;
  std::map<const Function *, ExFunc> ExportedFunctions;
  std::map<std::string, ExFunc> FuncNames;
#ifdef USE_LIBFFI
  std::map<const Function *, RawFunc> RawFunctions;
#endif
};

Functions &getFunctions() {
  static Functions F;
  return F;
}

} // anonymous namespace

static Interpreter *TheInterpreter;

static char getTypeID(Type *Ty) {
  switch (Ty->getTypeID()) {
  case Type::VoidTyID:    return 'V';
  case Type::IntegerTyID:
    switch (cast<IntegerType>(Ty)->getBitWidth()) {
      case 1:  return 'o';
      case 8:  return 'B';
      case 16: return 'S';
      case 32: return 'I';
      case 64: return 'L';
      default: return 'N';
    }
  case Type::FloatTyID:   return 'F';
  case Type::DoubleTyID:  return 'D';
  case Type::PointerTyID: return 'P';
  case Type::FunctionTyID:return 'M';
  case Type::StructTyID:  return 'T';
  case Type::ArrayTyID:   return 'A';
  default: return 'U';
  }
}

// Try to find address of external function given a Function object.
// Please note, that interpreter doesn't know how to assemble a
// real call in general case (this is JIT job), that's why it assumes,
// that all external functions has the same (and pretty "general") signature.
// The typical example of such functions are "lle_X_" ones.
static ExFunc lookupFunction(const Function *F) {
  // Function not found, look it up... start by figuring out what the
  // composite function name should be.
  std::string ExtName = "lle_";
  FunctionType *FT = F->getFunctionType();
  ExtName += getTypeID(FT->getReturnType());
  for (Type *T : FT->params())
    ExtName += getTypeID(T);
  ExtName += ("_" + F->getName()).str();

  auto &Fns = getFunctions();
  sys::ScopedLock Writer(Fns.Lock);
  ExFunc FnPtr = Fns.FuncNames[ExtName];
  if (!FnPtr)
    FnPtr = Fns.FuncNames[("lle_X_" + F->getName()).str()];
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
  if (!FnPtr && (F->getName().str().at(0) == '\x01')) {
	  std::string funcName = std::string(F->getName().substr(1,  F->getName().size() - 1)); 
	  FnPtr = Fns.FuncNames[("lle_X_" + funcName)];  
  }
#endif
  if (!FnPtr)  // Try calling a generic function... if it exists...
    FnPtr = (ExFunc)(intptr_t)sys::DynamicLibrary::SearchForAddressOfSymbol(
        ("lle_X_" + F->getName()).str());
  if (FnPtr)
    Fns.ExportedFunctions.insert(std::make_pair(F, FnPtr)); // Cache for later
  return FnPtr;
}

#ifdef USE_LIBFFI
static ffi_type *ffiTypeFor(Type *Ty) {
  switch (Ty->getTypeID()) {
    case Type::VoidTyID: return &ffi_type_void;
    case Type::IntegerTyID:
      switch (cast<IntegerType>(Ty)->getBitWidth()) {
        case 8:  return &ffi_type_sint8;
        case 16: return &ffi_type_sint16;
        case 32: return &ffi_type_sint32;
        case 64: return &ffi_type_sint64;
      }
      llvm_unreachable("Unhandled integer type bitwidth");
    case Type::FloatTyID:   return &ffi_type_float;
    case Type::DoubleTyID:  return &ffi_type_double;
    case Type::PointerTyID: return &ffi_type_pointer;
    default: break;
  }
  // TODO: Support other types such as StructTyID, ArrayTyID, OpaqueTyID, etc.
  // So, for Swift, it's a StructTyID that breaks things. 
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
  fprintf(thread_stderr, "Type error: type= %d \n", Ty->getTypeID());
#endif
  report_fatal_error("Type could not be mapped for use with libffi.");
  return NULL;
}

static void *ffiValueFor(Type *Ty, const GenericValue &AV,
                         void *ArgDataPtr) {
  switch (Ty->getTypeID()) {
    case Type::IntegerTyID:
      switch (cast<IntegerType>(Ty)->getBitWidth()) {
        case 8: {
          int8_t *I8Ptr = (int8_t *) ArgDataPtr;
          *I8Ptr = (int8_t) AV.IntVal.getZExtValue();
          return ArgDataPtr;
        }
        case 16: {
          int16_t *I16Ptr = (int16_t *) ArgDataPtr;
          *I16Ptr = (int16_t) AV.IntVal.getZExtValue();
          return ArgDataPtr;
        }
        case 32: {
          int32_t *I32Ptr = (int32_t *) ArgDataPtr;
          *I32Ptr = (int32_t) AV.IntVal.getZExtValue();
          return ArgDataPtr;
        }
        case 64: {
          int64_t *I64Ptr = (int64_t *) ArgDataPtr;
          *I64Ptr = (int64_t) AV.IntVal.getZExtValue();
          return ArgDataPtr;
        }
      }
      llvm_unreachable("Unhandled integer type bitwidth");
    case Type::FloatTyID: {
      float *FloatPtr = (float *) ArgDataPtr;
      *FloatPtr = AV.FloatVal;
      return ArgDataPtr;
    }
    case Type::DoubleTyID: {
      double *DoublePtr = (double *) ArgDataPtr;
      *DoublePtr = AV.DoubleVal;
      return ArgDataPtr;
    }
    case Type::PointerTyID: {
      void **PtrPtr = (void **) ArgDataPtr;
      *PtrPtr = GVTOP(AV);
      return ArgDataPtr;
    }
    default: break;
  }
  // TODO: Support other types such as StructTyID, ArrayTyID, OpaqueTyID, etc.
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
  fprintf(thread_stderr, "Type value error: type= %d \n", Ty->getTypeID());
#endif
  report_fatal_error("Type value could not be mapped for use with libffi.");
  return NULL;
}

static bool ffiInvoke(RawFunc Fn, Function *F, ArrayRef<GenericValue> ArgVals,
                      const DataLayout &TD, GenericValue &Result) {
  ffi_cif cif;
  FunctionType *FTy = F->getFunctionType();
  const unsigned NumArgs = F->arg_size();

  // TODO: We don't have type information about the remaining arguments, because
  // this information is never passed into ExecutionEngine::runFunction().
  if (ArgVals.size() > NumArgs && F->isVarArg()) {
    report_fatal_error("Calling external var arg function '" + F->getName()
                      + "' is not supported by the Interpreter.");
  }

  unsigned ArgBytes = 0;

  std::vector<ffi_type*> args(NumArgs);
  for (Function::const_arg_iterator A = F->arg_begin(), E = F->arg_end();
       A != E; ++A) {
    const unsigned ArgNo = A->getArgNo();
    Type *ArgTy = FTy->getParamType(ArgNo);
    args[ArgNo] = ffiTypeFor(ArgTy);
    ArgBytes += TD.getTypeStoreSize(ArgTy);
  }

  SmallVector<uint8_t, 128> ArgData;
  ArgData.resize(ArgBytes);
  uint8_t *ArgDataPtr = ArgData.data();
  SmallVector<void*, 16> values(NumArgs);
  for (Function::const_arg_iterator A = F->arg_begin(), E = F->arg_end();
       A != E; ++A) {
    const unsigned ArgNo = A->getArgNo();
    Type *ArgTy = FTy->getParamType(ArgNo);
    values[ArgNo] = ffiValueFor(ArgTy, ArgVals[ArgNo], ArgDataPtr);
    ArgDataPtr += TD.getTypeStoreSize(ArgTy);
  }

  Type *RetTy = FTy->getReturnType();
  ffi_type *rtype = ffiTypeFor(RetTy);

  if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, NumArgs, rtype, args.data()) ==
      FFI_OK) {
    SmallVector<uint8_t, 128> ret;
    if (RetTy->getTypeID() != Type::VoidTyID)
      ret.resize(TD.getTypeStoreSize(RetTy));
    ffi_call(&cif, Fn, ret.data(), values.data());
    switch (RetTy->getTypeID()) {
      case Type::IntegerTyID:
        switch (cast<IntegerType>(RetTy)->getBitWidth()) {
          case 8:  Result.IntVal = APInt(8 , *(int8_t *) ret.data()); break;
          case 16: Result.IntVal = APInt(16, *(int16_t*) ret.data()); break;
          case 32: Result.IntVal = APInt(32, *(int32_t*) ret.data()); break;
          case 64: Result.IntVal = APInt(64, *(int64_t*) ret.data()); break;
        }
        break;
      case Type::FloatTyID:   Result.FloatVal   = *(float *) ret.data(); break;
      case Type::DoubleTyID:  Result.DoubleVal  = *(double*) ret.data(); break;
      case Type::PointerTyID: Result.PointerVal = *(void **) ret.data(); break;
      default: break;
    }
    return true;
  }

  return false;
}
#endif // USE_LIBFFI

GenericValue Interpreter::callExternalFunction(Function *F,
                                               ArrayRef<GenericValue> ArgVals) {
  TheInterpreter = this;

  auto &Fns = getFunctions();
  std::unique_lock<sys::Mutex> Guard(Fns.Lock);

  // Do a lookup to see if the function is in our cache... this should just be a
  // deferred annotation!
  std::map<const Function *, ExFunc>::iterator FI =
      Fns.ExportedFunctions.find(F);
  if (ExFunc Fn = (FI == Fns.ExportedFunctions.end()) ? lookupFunction(F)
                                                      : FI->second) {
    Guard.unlock();
    return Fn(F->getFunctionType(), ArgVals);
  }

#ifdef USE_LIBFFI
  std::map<const Function *, RawFunc>::iterator RF = Fns.RawFunctions.find(F);
  RawFunc RawFn;
  if (RF == Fns.RawFunctions.end()) {
    RawFn = (RawFunc)(intptr_t)
      sys::DynamicLibrary::SearchForAddressOfSymbol(std::string(F->getName()));
    if (!RawFn)
      RawFn = (RawFunc)(intptr_t)getPointerToGlobalIfAvailable(F);
    if (RawFn != 0)
      Fns.RawFunctions.insert(std::make_pair(F, RawFn)); // Cache for later
  } else {
    RawFn = RF->second;
  }

  Guard.unlock();

  GenericValue Result;
  if (RawFn != 0 && ffiInvoke(RawFn, F, ArgVals, getDataLayout(), Result))
    return Result;
#endif // USE_LIBFFI

  if (F->getName() == "__main")
    errs() << "Tried to execute an unknown external function: "
      << *F->getType() << " __main\n";
  else
    report_fatal_error("Tried to execute an unknown external function: " +
                       F->getName());
#ifndef USE_LIBFFI
  errs() << "Recompiling LLVM with --enable-libffi might help.\n";
#endif
  return GenericValue();
}

//===----------------------------------------------------------------------===//
//  Functions "exported" to the running application...
//

// void atexit(Function*)
static GenericValue lle_X_atexit(FunctionType *FT,
                                 ArrayRef<GenericValue> Args) {
  assert(Args.size() == 1);
  TheInterpreter->addAtExitHandler((Function*)GVTOP(Args[0]));
  GenericValue GV;
  GV.IntVal = 0;
  return GV;
}

// void exit(int)
static GenericValue lle_X_exit(FunctionType *FT, ArrayRef<GenericValue> Args) {
	// TODO: insert here cleanup functions, if required.
  TheInterpreter->exitCalled(Args[0]);
  return GenericValue();
}

// void abort(void)
static GenericValue lle_X_abort(FunctionType *FT, ArrayRef<GenericValue> Args) {
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
       report_fatal_error("LLVM interpreter raised SIGABRT");
#else 
  //FIXME: should we report or raise here?
  //report_fatal_error("Interpreted program raised SIGABRT");
  raise (SIGABRT);
#endif
  return GenericValue();
}

// Silence warnings about sprintf. (See also
// https://github.com/llvm/llvm-project/issues/58086)
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
// int sprintf(char *, const char *, ...) - a very rough implementation to make
// output useful.
static GenericValue lle_X_sprintf(FunctionType *FT,
                                  ArrayRef<GenericValue> Args) {
  char *OutputBuffer = (char *)GVTOP(Args[0]);
  const char *FmtStr = (const char *)GVTOP(Args[1]);
  unsigned ArgNo = 2;

  // printf should return # chars printed.  This is completely incorrect, but
  // close enough for now.
  GenericValue GV;
  GV.IntVal = APInt(32, strlen(FmtStr));
  while (true) {
    switch (*FmtStr) {
    case 0: return GV;             // Null terminator...
    default:                       // Normal nonspecial character
      sprintf(OutputBuffer++, "%c", *FmtStr++);
      break;
    case '\\': {                   // Handle escape codes
      sprintf(OutputBuffer, "%c%c", *FmtStr, *(FmtStr+1));
      FmtStr += 2; OutputBuffer += 2;
      break;
    }
    case '%': {                    // Handle format specifiers
      char FmtBuf[100] = "", Buffer[1000] = "";
      char *FB = FmtBuf;
      *FB++ = *FmtStr++;
      char Last = *FB++ = *FmtStr++;
      unsigned HowLong = 0;
      while (Last != 'c' && Last != 'd' && Last != 'i' && Last != 'u' &&
             Last != 'o' && Last != 'x' && Last != 'X' && Last != 'e' &&
             Last != 'E' && Last != 'g' && Last != 'G' && Last != 'f' &&
             Last != 'p' && Last != 's' && Last != '%') {
        if (Last == 'l' || Last == 'L') HowLong++;  // Keep track of l's
        Last = *FB++ = *FmtStr++;
      }
      *FB = 0;

      switch (Last) {
      case '%':
        memcpy(Buffer, "%", 2); break;
      case 'c':
        sprintf(Buffer, FmtBuf, uint32_t(Args[ArgNo++].IntVal.getZExtValue()));
        break;
      case 'd': case 'i':
      case 'u': case 'o':
      case 'x': case 'X':
        if (HowLong >= 1) {
          if (HowLong == 1 &&
              TheInterpreter->getDataLayout().getPointerSizeInBits() == 64 &&
              sizeof(long) < sizeof(int64_t)) {
            // Make sure we use %lld with a 64 bit argument because we might be
            // compiling LLI on a 32 bit compiler.
            unsigned Size = strlen(FmtBuf);
            FmtBuf[Size] = FmtBuf[Size-1];
            FmtBuf[Size+1] = 0;
            FmtBuf[Size-1] = 'l';
          }
          sprintf(Buffer, FmtBuf, Args[ArgNo++].IntVal.getZExtValue());
        } else
          sprintf(Buffer, FmtBuf,uint32_t(Args[ArgNo++].IntVal.getZExtValue()));
        break;
      case 'e': case 'E': case 'g': case 'G': case 'f':
        sprintf(Buffer, FmtBuf, Args[ArgNo++].DoubleVal); break;
      case 'p':
        sprintf(Buffer, FmtBuf, (void*)GVTOP(Args[ArgNo++])); break;
      case 's':
        sprintf(Buffer, FmtBuf, (char*)GVTOP(Args[ArgNo++])); break;
      default:
        errs() << "<unknown printf code '" << *FmtStr << "'!>";
        ArgNo++; break;
      }
      size_t Len = strlen(Buffer);
      memcpy(OutputBuffer, Buffer, Len + 1);
      OutputBuffer += Len;
      }
      break;
    }
  }
  return GV;
}
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

// int printf(const char *, ...) - a very rough implementation to make output
// useful.
static GenericValue lle_X_printf(FunctionType *FT,
                                 ArrayRef<GenericValue> Args) {
  char Buffer[10000];
  std::vector<GenericValue> NewArgs;
  NewArgs.push_back(PTOGV((void*)&Buffer[0]));
  llvm::append_range(NewArgs, Args);
  GenericValue GV = lle_X_sprintf(FT, NewArgs);
  outs() << Buffer;
  return GV;
}

// int sscanf(const char *format, ...);
static GenericValue lle_X_sscanf(FunctionType *FT,
                                 ArrayRef<GenericValue> args) {
  assert(args.size() < 10 && "Only handle up to 10 args to sscanf right now!");

  char *Args[10];
  for (unsigned i = 0; i < args.size(); ++i)
    Args[i] = (char*)GVTOP(args[i]);

  GenericValue GV;
  GV.IntVal = APInt(32, sscanf(Args[0], Args[1], Args[2], Args[3], Args[4],
                    Args[5], Args[6], Args[7], Args[8], Args[9]));
  return GV;
}

// int scanf(const char *format, ...);
static GenericValue lle_X_scanf(FunctionType *FT, ArrayRef<GenericValue> args) {
  assert(args.size() < 10 && "Only handle up to 10 args to scanf right now!");

  char *Args[10];
  for (unsigned i = 0; i < args.size(); ++i)
    Args[i] = (char*)GVTOP(args[i]);

  GenericValue GV;
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
  outs().flush();
  fflush(thread_stdout);
  GV.IntVal = APInt(32, fscanf(thread_stdin, Args[0], Args[1], Args[2], Args[3], Args[4],
                  Args[5], Args[6], Args[7], Args[8], Args[9]));
#else
  GV.IntVal = APInt(32, scanf( Args[0], Args[1], Args[2], Args[3], Args[4],
                    Args[5], Args[6], Args[7], Args[8], Args[9]));
#endif
  return GV;
}

// int fprintf(FILE *, const char *, ...) - a very rough implementation to make
// output useful.
static GenericValue lle_X_fprintf(FunctionType *FT,
                                  ArrayRef<GenericValue> Args) {
  assert(Args.size() >= 2);
  char Buffer[10000];
  std::vector<GenericValue> NewArgs;
  NewArgs.push_back(PTOGV(Buffer));
  NewArgs.insert(NewArgs.end(), Args.begin()+1, Args.end());
  GenericValue GV = lle_X_sprintf(FT, NewArgs);

  fputs(Buffer, (FILE *) GVTOP(Args[0]));
  return GV;
}

static GenericValue lle_X_memset(FunctionType *FT,
                                 ArrayRef<GenericValue> Args) {
  int val = (int)Args[1].IntVal.getSExtValue();
  size_t len = (size_t)Args[2].IntVal.getZExtValue();
  memset((void *)GVTOP(Args[0]), val, len);
  // llvm.memset.* returns void, lle_X_* returns GenericValue,
  // so here we return GenericValue with IntVal set to zero
  GenericValue GV;
  GV.IntVal = 0;
  return GV;
}

static GenericValue lle_X_memcpy(FunctionType *FT,
                                 ArrayRef<GenericValue> Args) {
  memcpy(GVTOP(Args[0]), GVTOP(Args[1]),
         (size_t)(Args[2].IntVal.getLimitedValue()));

  // llvm.memcpy* returns void, lle_X_* returns GenericValue,
  // so here we return GenericValue with IntVal set to zero
  GenericValue GV;
  GV.IntVal = 0;
  return GV;
}

#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)

// Required because it's a vararg function
static GenericValue lle_X_open(FunctionType *FT,
                                 ArrayRef<GenericValue> Args) {
  int oflag = (int)Args[1].IntVal.getSExtValue();
  int returnValue;
  
  if (Args.size() == 2) {
         returnValue = ::open((char*)GVTOP(Args[0]), oflag);
  } else {
         int mode = (int)Args[2].IntVal.getSExtValue();
         returnValue = ::open((char*)GVTOP(Args[0]), oflag, mode);
         if (Args.size() > 3) errs() << "called open(" << (char*)GVTOP(Args[0]) << ", ...) with " << Args.size() << " arguments.\n"; 
  }
  GenericValue GV;
  GV.IntVal = APInt(32, returnValue);
  return GV;
}
// 
const char* llvm_ios_progname; 
//   void warn(const char *fmt, ...);
static GenericValue lle_X_warn(FunctionType *FT, ArrayRef<GenericValue> Args) {
       fputs(llvm_ios_progname, thread_stderr);
       const char *fmt = (const char *)GVTOP(Args[0]);
       if (fmt != NULL)
       {
               fputs(": ", thread_stderr);
               char Buffer[10000];
               std::vector<GenericValue> NewArgs;
               NewArgs.push_back(PTOGV((void*)&Buffer[0]));
               NewArgs.insert(NewArgs.end(), Args.begin(), Args.end());
               GenericValue GV = lle_X_sprintf(FT, NewArgs);
               fputs(Buffer, thread_stderr); 
       }
       fputs(": ", thread_stderr);
       fputs(strerror(errno), thread_stderr);
       putc('\n', thread_stderr);
       return GenericValue();
}
//   void warnx(const char *fmt, ...);
static GenericValue lle_X_warnx(FunctionType *FT, ArrayRef<GenericValue> Args) {
       fputs(llvm_ios_progname, thread_stderr);
       const char *fmt = (const char *)GVTOP(Args[0]);
       if (fmt != NULL)
       {
               fputs(": ", thread_stderr);
               char Buffer[10000];
               std::vector<GenericValue> NewArgs;
               NewArgs.push_back(PTOGV((void*)&Buffer[0]));
               NewArgs.insert(NewArgs.end(), Args.begin(), Args.end());
               GenericValue GV = lle_X_sprintf(FT, NewArgs);
               fputs(Buffer, thread_stderr); 
       }
       putc('\n', thread_stderr);
       return GenericValue();
}
// void err(int eval, const char *fmt, ...);
static GenericValue lle_X_err(FunctionType *FT, ArrayRef<GenericValue> Args) {
       std::vector<GenericValue> NewArgs = Args;
       NewArgs.erase(NewArgs.begin());
       lle_X_warn(FT, NewArgs); 
       TheInterpreter->exitCalled(Args[0]);
       return GenericValue();
}
//      void errx(int eval, const char *fmt, ...);
static GenericValue lle_X_errx(FunctionType *FT, ArrayRef<GenericValue> Args) {
       std::vector<GenericValue> NewArgs = Args;
       NewArgs.erase(NewArgs.begin());
       lle_X_warnx(FT, NewArgs); 
       TheInterpreter->exitCalled(Args[0]);
       return GenericValue();
}

#if 0
// Objective-C:
static GenericValue lle_X_objc_msgSend(FunctionType *FT,
                                 ArrayRef<GenericValue> args) {
       // Note: that method fails at runtime, with: 
       // selector () for message 'stringByAppendingString:' does not match selector known to Objective C runtime ()-- abort
       // Needs linking with -f Foundation -f CoreFoundation. HOW?

  id self = (objc_object *)GVTOP(args[0]); 
  SEL op = (SEL)GVTOP(args[1]);
    
  GenericValue GV;
  if (args.size() <= 2) 
         GV.PointerVal = *(void **) objc_msgSend(self, op); 
  else {
         objc_object *Args[10];
         for (unsigned i = 2; i < args.size(); ++i)
                 Args[i - 2] = (objc_object *)GVTOP(args[i]);

         GenericValue GV;
         // Add -lobjc to bootstrap.sh before removal
         GV.PointerVal = *(void **) (id)objc_msgSend(self, op, Args[0], Args[1], Args[2], Args[3], Args[4],
                         Args[5], Args[6], Args[7], Args[8], Args[9]);
  }
  return GV;
}
// 
#endif 

#endif //  (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)

void Interpreter::initializeExternalFunctions() {
  auto &Fns = getFunctions();
  sys::ScopedLock Writer(Fns.Lock);
  Fns.FuncNames["lle_X_atexit"]       = lle_X_atexit;
  Fns.FuncNames["lle_X_exit"]         = lle_X_exit;
  Fns.FuncNames["lle_X_abort"]        = lle_X_abort;

<<<<<<< HEAD
  (*FuncNames)["lle_X_printf"]       = lle_X_printf;
  (*FuncNames)["lle_X_sprintf"]      = lle_X_sprintf;
  (*FuncNames)["lle_X_sscanf"]       = lle_X_sscanf;
  (*FuncNames)["lle_X_scanf"]        = lle_X_scanf;
  (*FuncNames)["lle_X_fprintf"]      = lle_X_fprintf;
  (*FuncNames)["lle_X_memset"]       = lle_X_memset;
  (*FuncNames)["lle_X_memcpy"]       = lle_X_memcpy;
#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)
  // Variadic argument functions (vararg). 
  (*FuncNames)["lle_X_open"]     = lle_X_open;
  (*FuncNames)["lle_X__open"]     = lle_X_open;
  (*FuncNames)["lle_X_err"]     = lle_X_err;
  (*FuncNames)["lle_X_errx"]     = lle_X_errx;
  (*FuncNames)["lle_X_warn"]     = lle_X_warn;
  (*FuncNames)["lle_X_warnx"]     = lle_X_warnx;
  // objective-C -- todo again
  // (*FuncNames)["lle_X_objc_msgSend"]     = lle_X_objc_msgSend;
#endif
=======
  Fns.FuncNames["lle_X_printf"]       = lle_X_printf;
  Fns.FuncNames["lle_X_sprintf"]      = lle_X_sprintf;
  Fns.FuncNames["lle_X_sscanf"]       = lle_X_sscanf;
  Fns.FuncNames["lle_X_scanf"]        = lle_X_scanf;
  Fns.FuncNames["lle_X_fprintf"]      = lle_X_fprintf;
  Fns.FuncNames["lle_X_memset"]       = lle_X_memset;
  Fns.FuncNames["lle_X_memcpy"]       = lle_X_memcpy;
>>>>>>> 79949fd94538724224a771e12aeaa68ceeaada20
}
