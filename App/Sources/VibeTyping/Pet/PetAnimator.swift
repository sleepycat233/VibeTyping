import CoreGraphics
import SwiftUI

@MainActor
final class PetAnimator: ObservableObject {
    @Published private(set) var currentFrame: CGImage
    @Published private(set) var state: PetState = .idle

    private let atlas: PetAtlas
    private var animationTask: Task<Void, Never>?
    private var reducedMotion: Bool

    init(atlas: PetAtlas, reducedMotion: Bool) {
        self.atlas = atlas
        self.reducedMotion = reducedMotion
        currentFrame = atlas.frames[PetState.idle.atlasRow][0]
        start(.idle, restart: true)
    }

    deinit { animationTask?.cancel() }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotion != enabled else { return }
        reducedMotion = enabled
        start(state, restart: true)
    }

    func play(_ next: PetState) {
        start(next, restart: false)
    }

    private func start(_ next: PetState, restart: Bool) {
        guard restart || next != state else { return }
        animationTask?.cancel()
        state = next
        let frames = frames(for: next)
        currentFrame = frames[0]
        guard !reducedMotion, frames.count > 1 else { return }

        let duration = frameDuration(for: next)
        let finiteLoops = next == .review || next == .failed ? 3 : nil
        animationTask = Task { [weak self] in
            var index = 0
            var completedLoops = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(duration))
                guard !Task.isCancelled, let self else { return }
                index = (index + 1) % frames.count
                if index == 0 {
                    completedLoops += 1
                    if let finiteLoops, completedLoops >= finiteLoops {
                        self.play(.idle)
                        return
                    }
                }
                self.currentFrame = frames[index]
            }
        }
    }

    private func frames(for state: PetState) -> [CGImage] {
        let count = PetAnimationSpec.frameCount(for: state)
        return Array(atlas.frames[state.atlasRow].prefix(count))
    }

    private func frameDuration(for state: PetState) -> Int {
        switch state {
        case .idle: 220
        case .running: 120
        case .failed: 140
        case .waiting, .review: 150
        }
    }
}

enum PetAnimationSpec {
    static func frameCount(for state: PetState) -> Int {
        switch state {
        case .idle: 6
        case .failed: 8
        case .waiting, .running, .review: 6
        }
    }
}
