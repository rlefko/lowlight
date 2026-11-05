// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import AudioToolbox
import Darwin
import Synchronization

/// The most recent positive-size source pull, not the device's audible position.
public enum SessionAudioSourceStatus: UInt32, Sendable {
    case ready, rendering, waitingForPreparation, finished, failed
}

public enum SessionAudioSourceError: Error { case formatUnavailable }

/// A single-consumer audio-graph bridge to the existing preparation worker.
/// Construct and connect off the callback. The block always supplies 32 kHz interleaved
/// Float32 stereo; AVAudioSourceNode performs any PCM conversion at its output connection.
/// Stop and quiesce the engine/consumer, then stop/join preparation and detach/release the
/// node off the callback. Worker shutdown alone does not stop rendering. The node pins both
/// owners even after this wrapper is released; no callback reclaims either owner.
public final class SessionAudioSource {
    public let node: AVAudioSourceNode
    public let format: AVAudioFormat
    private let state: RenderState

    public init(worker: SessionPreparationWorker) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 32_000, channels: 2, interleaved: true)
        else { throw SessionAudioSourceError.formatUnavailable }
        let state = RenderState(worker: worker, endpoint: try worker.makeRenderEndpoint())
        self.state = state
        self.format = format
        worker.setRenderFailureProbe { [weak state] in state?.status == .failed }
        node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, outputData in
            state.render(isSilence: isSilence, frameCount: frameCount, outputData: outputData)
        }
    }

    /// Independent atomic snapshots; these are not one transactional device-clock reading.
    public var status: SessionAudioSourceStatus { state.status }
    public var position: UInt64 { state.endpoint.position }
    public var frameCount: UInt64 { state.endpoint.frameCount }
    public var finiteFrameCount: UInt64? { state.endpoint.finiteFrameCount }
    public var isFinished: Bool { state.endpoint.isFinished }
    public var isFaulted: Bool { state.status == .failed || state.endpoint.isFaulted }

    // Direct callback seam: never invoke while the node has another render consumer.
    func render(
        isSilence: UnsafeMutablePointer<ObjCBool>, frameCount: AVAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        state.render(isSilence: isSilence, frameCount: frameCount, outputData: outputData)
    }

    private final class RenderState: Sendable {
        private let worker: SessionPreparationWorker
        let endpoint: PreparedSession.RenderEndpoint
        private let value = Atomic(SessionAudioSourceStatus.ready.rawValue)

        init(worker: SessionPreparationWorker, endpoint: PreparedSession.RenderEndpoint) {
            self.worker = worker
            self.endpoint = endpoint
        }

        var status: SessionAudioSourceStatus {
            SessionAudioSourceStatus(rawValue: value.load(ordering: .relaxed)) ?? .failed
        }

        func render(
            isSilence: UnsafeMutablePointer<ObjCBool>, frameCount: AVAudioFrameCount,
            outputData: UnsafeMutablePointer<AudioBufferList>
        ) -> OSStatus {
            isSilence.pointee = true
            guard frameCount > 0 else { return noErr }
            guard outputData.pointee.mNumberBuffers == 1 else { return fail(outputData) }
            let buffer = outputData.pointee.mBuffers
            let requiredBytes = UInt64(frameCount) * 2 * UInt64(MemoryLayout<Float>.stride)
            guard buffer.mNumberChannels == 2,
                UInt64(buffer.mDataByteSize) >= requiredBytes,
                let data = buffer.mData,
                UInt(bitPattern: data).isMultiple(of: UInt(MemoryLayout<Float>.alignment))
            else { return fail(outputData) }
            guard status != .failed else {
                clear(outputData)
                return noErr
            }
            let output = UnsafeMutableBufferPointer(
                start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount) * 2)
            guard let written = endpoint.render(into: output) else {
                clear(outputData)
                value.store(SessionAudioSourceStatus.failed.rawValue, ordering: .relaxed)
                return noErr
            }
            // Never wait/re-pull to fill an underflow. Native rendering clears the unused
            // capacity and freezes musical time; the device may consume that silence.
            isSilence.pointee = ObjCBool(written == 0)
            let next: SessionAudioSourceStatus =
                endpoint.isFinished
                ? .finished : (written < Int(frameCount) ? .waitingForPreparation : .rendering)
            value.store(next.rawValue, ordering: .relaxed)
            return noErr
        }

        private func fail(_ outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
            clear(outputData)
            value.store(SessionAudioSourceStatus.failed.rawValue, ordering: .relaxed)
            return kAudio_ParamError
        }

        private func clear(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
            let count = Int(outputData.pointee.mNumberBuffers)
            guard count > 0 else { return }
            withUnsafeMutablePointer(to: &outputData.pointee.mBuffers) { first in
                var index = 0
                while index < count {
                    let buffer = first[index]
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                    index += 1
                }
            }
        }
    }
}
