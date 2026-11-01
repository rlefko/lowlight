// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

/// Off-callback work only. The C scope restores the calling thread before errors rethrow.
enum PreparationMode {
    private final class Invocation {
        let run: () -> Void

        init(run: @escaping () -> Void) { self.run = run }
    }

    @inline(never)
    static func perform<Value>(_ body: () throws -> Value) throws -> Value {
        try withoutActuallyEscaping(body) { work in
            var outcome: Result<Value, any Error>?
            let invocation = Invocation { outcome = Result(catching: work) }
            let completed = withExtendedLifetime(invocation) {
                ll_with_preparation_mode(
                    { context in
                        guard let context else {
                            preconditionFailure("Missing synchronous preparation context")
                        }
                        Unmanaged<Invocation>.fromOpaque(context).takeUnretainedValue().run()
                    }, Unmanaged.passUnretained(invocation).toOpaque())
            }
            guard completed, let outcome else {
                preconditionFailure("Synchronous preparation did not produce a result")
            }
            return try outcome.get()
        }
    }
}
