# The LLVM Compiler Infrastructure

[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/llvm/llvm-project/badge)](https://securityscorecards.dev/viewer/?uri=github.com/llvm/llvm-project)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/8273/badge)](https://www.bestpractices.dev/projects/8273)
[![libc++](https://github.com/llvm/llvm-project/actions/workflows/libcxx-build-and-test.yaml/badge.svg?branch=main&event=schedule)](https://github.com/llvm/llvm-project/actions/workflows/libcxx-build-and-test.yaml?query=event%3Aschedule)

Welcome to the LLVM project!

This repository contains the source code for LLVM, a toolkit for the
construction of highly optimized compilers, optimizers, and run-time
environments.

The LLVM project has multiple components. The core of the project is
itself called "LLVM". This contains all of the tools, libraries, and header
files needed to process intermediate representations and convert them into
object files. Tools include an assembler, disassembler, bitcode analyzer, and
bitcode optimizer.

C-like languages use the [Clang](http://clang.llvm.org/) frontend. This
component compiles C, C++, Objective-C, and Objective-C++ code into LLVM bitcode
-- and from there into object files, using LLVM.

Other components include:
the [libc++ C++ standard library](https://libcxx.llvm.org),
the [LLD linker](https://lld.llvm.org), and more.

## Getting the Source Code and Building LLVM

Consult the
[Getting Started with LLVM](https://llvm.org/docs/GettingStarted.html#getting-started-with-llvm)
page for detailed information on configuring and compiling LLVM. You can visit
[Directory Layout](https://llvm.org/docs/GettingStarted.html#directory-layout)
to learn about the layout of the source code tree.

iOS version specific information
================================

This is a very experimental port. It's is designed to work inside ios_system
(https://github.com/holzschu/ios_system), which itself is supposed to be 
embedded inside shell applications such as OpenTerm, a-Shell or Blink:
- https://github.com/louisdh/terminal
- https://github.com/holzschu/a-Shell

Compilation of the entire package takes several hours (divided by the number of 
cores you can give to the compiler). 

The steps for compilation are:
- compile LLVM, clang, lld, libcxx and libcxxabi for OSX
- make sure ios_system has been compiled, and if not compile it.
- compile LLVM and clang for iOS and the Simulator (that's the long step)

"bootstrap.sh" in this directory takes care of all these steps. Remember, 
you have time for a long walk in the woods while it compiles. 

You can also embed the precompiled Swift binary packages from the release, using Xcode -> Swift Packages -> Add package dependency for Xcode 12 and above. 

Once you have compiled everything, add the binaries you want (at least clang) 
to the list of embedded binaries, along with libLLVM.dylib and libclang.dylib.

Once you have the binaries inside your app, you need to provide the header files. I copied them from `wasi-sdk`: https://github.com/holzschu/wasi-sdk since the focus is on creating webAssembly files, but you can also copy from the Xcode iPhone SDK if you plan on compiling for iOS (you will not be able to execute files compiled for iOS without signing them, which requires moving them to a Mac, but still). 

I welcome all help on this project, including on this README file. 


[Getting Started with LLVM](https://llvm.org/docs/GettingStarted.html#getting-the-source-code-and-building-llvm)
page for information on building and running LLVM.

For information on how to contribute to the LLVM project, please take a look at
the [Contributing to LLVM](https://llvm.org/docs/Contributing.html) guide.

## Getting in touch

Join the [LLVM Discourse forums](https://discourse.llvm.org/), [Discord
chat](https://discord.gg/xS7Z362),
[LLVM Office Hours](https://llvm.org/docs/GettingInvolved.html#office-hours) or
[Regular sync-ups](https://llvm.org/docs/GettingInvolved.html#online-sync-ups).

The LLVM project has adopted a [code of conduct](https://llvm.org/docs/CodeOfConduct.html) for
participants to all modes of communication within the project.
