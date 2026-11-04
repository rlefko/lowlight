// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import AudioToolbox
import Foundation
import Testing

@testable import LowlightAudio

struct SessionAudioSourceBufferTests {
    @Test func malformedBuffersFailWithoutAdvancingOrWritingOutsideTheirCapacity() throws {
        for invalid in 0..<6 {
            let score = try SourceTestScore()
            let worker = try score.makeWorker()
            defer {
                worker.requestStop()
                worker.join()
            }
            let source = try SessionAudioSource(worker: worker)
            var samples = [Float](repeating: 1, count: 34)
            samples.withUnsafeMutableBytes { storage in
                // Guard four bytes on either side of the advertised writable buffer.
                let start = storage.baseAddress?.advanced(by: 4)
                var buffer = AudioBuffer(mNumberChannels: 2, mDataByteSize: 128, mData: start)
                var count: UInt32 = 1
                var frames: UInt32 = 16
                switch invalid {
                case 0: buffer.mNumberChannels = 1
                case 1: count = 0
                case 2: buffer.mDataByteSize = 7
                case 3: buffer.mData = nil
                case 4:
                    buffer.mData = start?.advanced(by: 1)
                    buffer.mDataByteSize = 127
                default: frames = .max
                }
                var list = AudioBufferList(mNumberBuffers: count, mBuffers: buffer)
                let before = Array(storage)
                var silence: ObjCBool = false
                #expect(
                    source.render(isSilence: &silence, frameCount: frames, outputData: &list)
                        == kAudio_ParamError)
                #expect(silence.boolValue && source.isFaulted && source.status == .failed)
                #expect(source.position == 0)
                let offset = invalid == 4 ? 5 : 4
                let length = count == 0 || buffer.mData == nil ? 0 : Int(buffer.mDataByteSize)
                let cleared = offset..<(offset + length)
                for index in storage.indices {
                    #expect(storage[index] == (cleared.contains(index) ? 0 : before[index]))
                }
                // A later valid request cannot resume a faulted graph or advance music.
                list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 128, mData: start))
                silence = false
                #expect(
                    source.render(isSilence: &silence, frameCount: 16, outputData: &list) == noErr)
                #expect(silence.boolValue && source.position == 0 && source.status == .failed)
                #expect(storage[4..<132].allSatisfy { $0 == 0 })
                #expect(Array(storage.prefix(4)) == Array(before.prefix(4)))
                #expect(Array(storage.suffix(4)) == Array(before.suffix(4)))
            }
        }
    }

    @Test func zeroFramesAreANoopAndPlanarBuffersAreRejectedAndCleared() throws {
        let score = try SourceTestScore()
        let worker = try score.makeWorker()
        defer {
            worker.requestStop()
            worker.join()
        }
        let source = try SessionAudioSource(worker: worker)
        var empty = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        var silence: ObjCBool = false
        #expect(source.render(isSilence: &silence, frameCount: 0, outputData: &empty) == noErr)
        #expect(silence.boolValue && source.position == 0 && source.status == .ready)
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { buffers.unsafeMutablePointer.deallocate() }
        var samples = [Float](repeating: 1, count: 32)
        samples.withUnsafeMutableBytes { storage in
            buffers[0] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 64, mData: storage.baseAddress)
            buffers[1] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 64,
                mData: storage.baseAddress?.advanced(by: 64))
            #expect(
                source.render(
                    isSilence: &silence, frameCount: 16, outputData: buffers.unsafeMutablePointer)
                    == kAudio_ParamError)
        }
        #expect(samples.allSatisfy { $0 == 0 })
        #expect(source.position == 0 && source.isFaulted && silence.boolValue)
    }

    @Test func retainedNodePinsBothOwnersWithoutRetainingItsWrapper() throws {
        let score = try SourceTestScore()
        weak var wrapper: SessionAudioSource?
        weak var nodeLifetime: AVAudioSourceNode?
        try autoreleasepool {
            var retainedNode: AVAudioSourceNode?
            try autoreleasepool {
                let worker = try score.makeWorker()
                let source = try SessionAudioSource(worker: worker)
                wrapper = source
                retainedNode = source.node
                nodeLifetime = source.node
                #expect(throws: PreparationWorkerError.renderEndpointUnavailable) {
                    try SessionAudioSource(worker: worker)
                }
            }
            #expect(wrapper == nil && nodeLifetime != nil && score.worker != nil)
            // No consumer is running; joining preparation does not release node-owned state.
            score.worker?.requestStop()
            score.worker?.join()
            #expect(score.session != nil && score.pool?.reservedRacks == 2)
            withExtendedLifetime(retainedNode) {}
            retainedNode = nil
        }
        #expect(nodeLifetime == nil && score.worker == nil && score.session == nil)
        #expect(score.pool?.reservedRacks == 0)
    }
}
