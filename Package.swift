// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "llvm",
    products: [
        .library(name: "llvm", targets: ["ar", "lld", "llc", "clang", "dis", "libLLVM", "link", "lli", "nm", "opt"])
    ],
    dependencies: [
    ],
    targets: [
        .binaryTarget(
            name: "ar",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/ar.xcframework.zip",
            checksum: "69727d7f851ad5b0a77732e7cff70112a0cf8ec12d8e8fc869f6470a1880c1c5"
        ),
        .binaryTarget(
            name: "lld",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/lld.xcframework.zip",
            checksum: "240c1cd5cfc7557dd859af9b9d20aa9623f935dc92746a8be21edba8dbd11f34"
        ),
        .binaryTarget(
            name: "llc",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/llc.xcframework.zip",
            checksum: "bfd1cf1e42a5af03716bdd0d3d5404cde7d56f86c52cfebcc69a7ecbd2d5127b"
        ),
        .binaryTarget(
            name: "clang",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/clang.xcframework.zip",
            checksum: "9de9f72334c99f27d3ac5844b8d3feffcaed3086997e7c2538f887667e8ca179"
        ),
        .binaryTarget(
            name: "dis",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/dis.xcframework.zip",
            checksum: "6613ee063331e39fdea044cc119511ef61df8eb247e6db2e376240af224623c7"
        ),
        .binaryTarget(
            name: "libLLVM",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/libLLVM.xcframework.zip",
            checksum: "bbae5b3a7952b2f1e89fb93b25b41931a53b6d8c99d24dfe6a893e615b177428"
        ),
        .binaryTarget(
            name: "link",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/link.xcframework.zip",
            checksum: "3bf79972c961f418c9964df04dec81794dd6beae88f07702e8b51e074ed2085f"
        ),
        .binaryTarget(
            name: "lli",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/lli.xcframework.zip",
            checksum: "a7976820f7349daf1c136ae513d506c954502ff10b92a92dbd3538bd625e0719"
        ),
        .binaryTarget(
            name: "nm",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/nm.xcframework.zip",
            checksum: "3c004f6d5345bde727bb34d2daa252c46a9cf5ee3e053c7a18b2933cf0df16c0"
        ),
        .binaryTarget(
            name: "opt",
            url: "https://github.com/holzschu/llvm-project/releases/download/14.0.0/opt.xcframework.zip",
            checksum: "616d858d3bfd3f2782baedda34ba1fb6c449704faeae0db59e742d27169710ab"
        )
    ]
)



/* Merging into xcframeworks: 
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/ar.xcframework
b64e6430fafa6353734229cf3f36efac3b3bb00cfa271ba83b95992a479f3704
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/lld.xcframework
f49af64fcef79629277473d159db802f4772cc0fce4b76a30d77fc7177e572d1
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/llc.xcframework
93952531fb43d799b0a0ffb6cc9cc351e71245edb133ee2e0ed4592df7b3f0c9
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/clang.xcframework
d0f45645bca98f49a3acd926a34b80a9403586fde28ffbba5b766980d24776a8
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/dis.xcframework
fc8c0aca29e0a8653aea5343b6585e94b3d550a40b35477d18549a0434df1b3a
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/libLLVM.xcframework
2e5f05afd237b79ed264759b602c31af0907cab5bc45af2851d971358f412d4f
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/link.xcframework
e4b3531bd3ca702ddf5c1f652da8c83b956ab6d8b19107de0972b4da3151e781
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/lli.xcframework
469fa5fae7dc51c5195661505c5a32f3023a2136ed3057c79baae27b19eff220
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/nm.xcframework
ddb50953b2b6b2e9331a992b7f861ad0f2581788b2520b526ec4c8ca86bada3b
xcframework successfully written out to: /Users/holzschu/src/Xcode_iPad/llvm-project/opt.xcframework
13c5748e2f5280879b7c28711c99648d850b75147c961e5031e0dabb8efd8cb9

 */
