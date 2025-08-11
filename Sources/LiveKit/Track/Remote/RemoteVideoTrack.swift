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
    private lazy var _proxyRender = VideoRendererProxy()
    private var useProxyRender: Bool = true
    
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
        
        log("*track: init", .debug)

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
            let ptr = Unmanaged.passUnretained(self as AnyObject).toOpaque()
            let className = String(describing: type(of: self))
            Task.detached {
                logger.debug("[\(className):\(ptr)] *track: deinit beg")
                rtcVideoTrack.remove(proxyRender)
                logger.debug("[\(className):\(ptr)] *track: deinit end")
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

        _state.mutate {
            $0.videoRenderers.add(videoRenderer)
        }

        if (useProxyRender) {
            _proxyRender.add(render: videoRenderer)
        } else {
            rtcVideoTrack.add(VideoRendererAdapter(target: videoRenderer))
        }
    }

    public func remove(videoRenderer: VideoRenderer) {
        guard let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        _state.mutate {
            $0.videoRenderers.remove(videoRenderer)
        }

        if (useProxyRender) {
            _proxyRender.remove(render: videoRenderer)
        } else {
            rtcVideoTrack.remove(VideoRendererAdapter(target: videoRenderer))
        }
    }
}
