//
//  VideoPresentationHost.swift
//  Pangolin
//

import SwiftUI

struct VideoPresentationHost: View {
    let selectedVideo: Video?
    let isVideoDetailActive: Bool
    let playerViewModel: VideoPlayerViewModel
    @ObservedObject var floatingState: FloatingVideoState
    @ObservedObject var frameController: VideoPresentationFrameController

    var body: some View {
        GeometryReader { geometry in
            let overlayFrameInRoot = geometry.frame(
                in: .named(VideoFloatingCoordinateSpace.root)
            )
            let outerSafeBounds = VideoPresentationHostLayout.availableBounds(
                size: geometry.size,
                insets: geometry.safeAreaInsets
            )
            let presentationViewportFrame = VideoPlayerPresentationPolicy.overlayLocalFrame(
                floatingState.presentationViewportFrame,
                overlayFrameInRoot: overlayFrameInRoot
            )
            let availableBounds = VideoPresentationHostLayout.availableBounds(
                outerBounds: outerSafeBounds,
                presentationViewportFrame: presentationViewportFrame
            )
            let dockedFrame = VideoPlayerPresentationPolicy.overlayLocalFrame(
                floatingState.inlineFrame,
                overlayFrameInRoot: overlayFrameInRoot
            )

            if let video = presentedVideo(
                dockedFrame: dockedFrame,
                availableBounds: availableBounds
            ), let dockedFrame {
                FloatingVideoPane(
                    video: video,
                    playerViewModel: playerViewModel,
                    floatingState: floatingState,
                    frameController: frameController,
                    dockedFrame: dockedFrame,
                    availableBounds: availableBounds
                )
                .id(video.id)
                .zIndex(100)
            }
            Color.clear
                .allowsHitTesting(false)
                .onChange(of: floatingState.inlineFrame, initial: true) { _, _ in
                    prepareFloatingDestination(
                        dockedFrame: dockedFrame,
                        availableBounds: availableBounds
                    )
                }
                .onChange(of: floatingState.inlineWidth) { _, _ in
                    prepareFloatingDestination(
                        dockedFrame: dockedFrame,
                        availableBounds: availableBounds
                    )
                }
                .onChange(of: floatingState.presentationViewportFrame) { _, _ in
                    prepareFloatingDestination(
                        dockedFrame: dockedFrame,
                        availableBounds: availableBounds
                    )
                }
                .onChange(of: geometry.size) { _, _ in
                    prepareFloatingDestination(
                        dockedFrame: dockedFrame,
                        availableBounds: availableBounds
                    )
                }
                .onChange(of: geometry.safeAreaInsets) { _, _ in
                    prepareFloatingDestination(
                        dockedFrame: dockedFrame,
                        availableBounds: availableBounds
                    )
                }
                .onChange(of: playerViewModel.videoAspectRatio) { _, _ in
                    prepareFloatingDestination(
                        dockedFrame: dockedFrame,
                        availableBounds: availableBounds
                    )
                }
        }
        .clipped()
        .zIndex(100)
    }

    private func presentedVideo(
        dockedFrame: CGRect?,
        availableBounds: CGRect
    ) -> Video? {
        guard isVideoDetailActive,
              let selectedVideo,
              let selectedVideoID = selectedVideo.id,
              floatingState.videoID == selectedVideoID,
              dockedFrame != nil,
              !availableBounds.isEmpty,
              VideoPlayerPresentationPolicy.destination(
                  isFloating: floatingState.isFloating,
                  inlineFrame: floatingState.inlineFrame,
                  floatingFrame: floatingState.frame
              ) != nil else {
            return nil
        }

        return selectedVideo
    }

    private func prepareFloatingDestination(
        dockedFrame: CGRect?,
        availableBounds: CGRect
    ) {
        guard isVideoDetailActive,
              let selectedVideoID = selectedVideo?.id,
              floatingState.videoID == selectedVideoID,
              dockedFrame != nil,
              floatingState.inlineWidth.isFinite,
              floatingState.inlineWidth > 0,
              !availableBounds.isEmpty else {
            return
        }

        floatingState.prepareFloatingDestination(
            in: availableBounds,
            aspectRatio: playerViewModel.videoAspectRatio
        )
    }
}
