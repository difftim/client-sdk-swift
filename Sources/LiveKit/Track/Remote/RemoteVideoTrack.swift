/*
 * Copyright 2025 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

internal import LiveKitWebRTC

@objc
public class RemoteVideoTrack: Track, RemoteTrack, @unchecked Sendable {
    
    init(name: String,
         source: Track.Source,
         track: LKRTCMediaStreamTrack,
         reportStatistics: Bool)
    {
        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: track,
                   reportStatistics: reportStatistics)
        
        log("*track: init")

        guard useProxyRender else {
            return
        }
        
        guard let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }
        
        rtcVideoTrack.add(_proxyRender)
    }
    
    deinit {
        guard useProxyRender else {
            return
        }

        if let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack {
            let proxyRender = _proxyRender
            let ptr = String(describing: Unmanaged.passUnretained(self as AnyObject).toOpaque())
            Task.detached {
                logger.log("*track: deinit beg", type: RemoteVideoTrack.self, ptr: ptr)
                rtcVideoTrack.remove(proxyRender)
                logger.log("*track: deinit end", type: RemoteVideoTrack.self, ptr: ptr)
            }
        }
    }
    
}
// MARK: - VideoTrack Protocol

extension RemoteVideoTrack: VideoTrack {
    public func add(videoRenderer: VideoRenderer) {
        guard let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        let adapter = VideoRendererAdapter(renderer: videoRenderer)

        _state.mutate {
            $0.videoRendererAdapters.setObject(adapter, forKey: videoRenderer)
        }

        rtcVideoTrack.add(adapter)
    }

    public func remove(videoRenderer: VideoRenderer) {
        guard let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        let adapter = _state.mutate {
            let adapter = $0.videoRendererAdapters.object(forKey: videoRenderer)
            $0.videoRendererAdapters.removeObject(forKey: videoRenderer)
            return adapter
        }

        guard let adapter else {
            log("No adapter found for videoRenderer", .warning)
            return
        }

        rtcVideoTrack.remove(adapter)
    }
}
