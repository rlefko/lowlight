# 001: Native foundation and pinned tools

Use a checked-in Xcode project and shared Lowlight scheme, SwiftUI, iOS 18 deployment, and no runtime dependencies. Keep the first change limited to launch/About behavior and the development workflow. Engine imports and final visuals follow in separate reviewed milestones.

Pin Xcode 26.6 (17F113), Swift 6.3.3, and the bundled `swift format` 6.3.0 on the macOS 26 runner. The local toolchain matches. SwiftLint is pinned separately by version and download checksum. Never replace the formatter with a competing implementation.

Ordinary builds may restore keyed DerivedData. CodeQL gets a separate clean traced Swift device build, without compiler caches. Add C/C++ or Python analysis only when maintained code in those languages is introduced. A successful SARIF upload is not evidence that findings are absent; repository code-scanning protection must be checked separately.

See [contributing](../contributing.md) for verified upstream references and [performance](../performance.md) for targets that need hardware evidence.
