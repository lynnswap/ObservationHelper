import Foundation
import Observation

/// Wraps `withObservationTracking` to observe one or more values and trigger
/// change handlers with optional debouncing.
@MainActor
public struct ObservationScheduler {
    public typealias TrackingBlock = () -> Void
    public typealias ChangeHandler = () -> Void

    private let track: TrackingBlock
    private var delay: ContinuousClock.Duration?
    private var initial = false

    public init(_ track: @escaping TrackingBlock) {
        self.track = track
    }

    public func debounce(_ delay: ContinuousClock.Duration?) -> ObservationScheduler {
        var copy = self
        copy.delay = delay
        return copy
    }

    public func initial(_ shouldFire: Bool = true) -> ObservationScheduler {
        var copy = self
        copy.initial = shouldFire
        return copy
    }

    public func onChange(initial: Bool, _ handler: @escaping ChangeHandler) -> ObservationScheduler.Handle {
        var copy = self
        copy.initial = initial
        return copy.onChange(handler)
    }

    public func onChange(_ handler: @escaping ChangeHandler) -> ObservationScheduler.Handle {
        ObservationScheduler.Handle(
            debounce: delay,
            initial: initial,
            track: track,
            onChange: handler
        )
    }

    public static func observe(_ track: @escaping TrackingBlock) -> ObservationScheduler {
        ObservationScheduler(track)
    }
}

public extension ObservationScheduler {
    @MainActor
    public final class Handle {
        private let track: TrackingBlock
        private var onChange: ChangeHandler?
        private let delay: ContinuousClock.Duration?
        private var pendingTask: Task<Void, Never>?
        private var isCancelled = false

        fileprivate init(
            debounce delay: ContinuousClock.Duration?,
            initial: Bool,
            track: @escaping TrackingBlock,
            onChange: @escaping ChangeHandler
        ) {
            self.track = track
            self.onChange = onChange
            self.delay = delay

            observe(initial: initial)
        }

        public func cancel() {
            isCancelled = true
            pendingTask?.cancel()
            pendingTask = nil
            onChange = nil
        }

        private func observe(initial: Bool) {
            guard !isCancelled else { return }

            withObservationTracking {
                track()
            } onChange: { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isCancelled else { return }
                    self.scheduleChange()
                    self.observe(initial: false)
                }
            }

            if initial {
                fireNow()
            }
        }

        private func scheduleChange() {
            pendingTask?.cancel()

            guard let delay else {
                fireNow()
                return
            }

            pendingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !self.isCancelled else { return }
                self.fireNow()
            }
        }

        private func fireNow() {
            guard !isCancelled else { return }
            onChange?()
        }
    }
}

@MainActor
public extension ObservationScheduler.Handle {
    convenience init<Target: AnyObject & Observable, Value>(
        target: Target,
        keyPath: KeyPath<Target, Value>,
        debounce delay: ContinuousClock.Duration? = nil,
        initial: Bool = false,
        onChange: @escaping ObservationScheduler.ChangeHandler
    ) {
        self.init(
            debounce: delay,
            initial: initial,
            track: { [weak target] in
                guard let target else { return }
                _ = target[keyPath: keyPath]
            },
            onChange: onChange
        )
    }
}

@MainActor
public extension Observable where Self: AnyObject {
    func observeDebounced<Value>(
        _ keyPath: KeyPath<Self, Value>,
        debounce delay: ContinuousClock.Duration? = nil,
        initial: Bool = false,
        onChange: @escaping ObservationScheduler.ChangeHandler
    ) -> ObservationScheduler.Handle {
        ObservationScheduler.Handle(
            target: self,
            keyPath: keyPath,
            debounce: delay,
            initial: initial,
            onChange: onChange
        )
    }

    func callAsFunction<Value>(
        _ keyPath: KeyPath<Self, Value>,
        debounce delay: ContinuousClock.Duration? = nil,
        initial: Bool = false,
        onChange: @escaping ObservationScheduler.ChangeHandler
    ) -> ObservationScheduler.Handle {
        observeDebounced(
            keyPath,
            debounce: delay,
            initial: initial,
            onChange: onChange
        )
    }
}

extension ObservationScheduler.Handle: Hashable {
    public nonisolated static func == (lhs: ObservationScheduler.Handle, rhs: ObservationScheduler.Handle) -> Bool {
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

public extension ObservationScheduler.Handle {
    func store(in storage: inout Set<ObservationScheduler.Handle>) {
        storage.insert(self)
    }
}
