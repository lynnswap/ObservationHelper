import Foundation
import Observation

/// Wraps `withObservationTracking` to observe one or more values and trigger
/// change handlers with optional debouncing.
public struct ObservationScheduler {
    public typealias TrackingBlock = () -> Void
    public typealias ChangeHandler = () -> Void

    private struct Configuration {
        var track: TrackingBlock
        var delay: ContinuousClock.Duration?
        var initial = false
    }

    private let configuration: Configuration?
    private let handle: Handle?

    @MainActor
    public init(_ track: @escaping TrackingBlock) {
        self.configuration = Configuration(track: track)
        self.handle = nil
    }

    private init(configuration: Configuration?, handle: Handle?) {
        self.configuration = configuration
        self.handle = handle
    }

    @MainActor
    public func debounce(_ delay: ContinuousClock.Duration?) -> ObservationScheduler {
        guard handle == nil, let configuration else { return self }
        var config = configuration
        config.delay = delay
        return ObservationScheduler(configuration: config, handle: nil)
    }

    @MainActor
    public func initial(_ shouldFire: Bool = true) -> ObservationScheduler {
        guard handle == nil, let configuration else { return self }
        var config = configuration
        config.initial = shouldFire
        return ObservationScheduler(configuration: config, handle: nil)
    }

    @MainActor
    public func onChange(initial: Bool, _ handler: @escaping ChangeHandler) -> ObservationScheduler {
        guard handle == nil, let configuration else { return self }
        var config = configuration
        config.initial = initial
        return ObservationScheduler(configuration: config, handle: nil).onChange(handler)
    }

    @MainActor
    public func onChange(_ handler: @escaping ChangeHandler) -> ObservationScheduler {
        guard handle == nil, let configuration else { return self }
        let runningHandle = Handle(
            debounce: configuration.delay,
            initial: configuration.initial,
            track: configuration.track,
            onChange: handler
        )
        return ObservationScheduler(configuration: nil, handle: runningHandle)
    }

    @MainActor
    public func cancel() {
        handle?.cancel()
    }

    @MainActor
    public func store(in storage: inout Set<ObservationScheduler>) {
        guard handle != nil else { return }
        storage.insert(self)
    }

    @MainActor
    public static func observe(_ track: @escaping TrackingBlock) -> ObservationScheduler {
        ObservationScheduler(track)
    }
}

extension ObservationScheduler: Hashable {
    public static func == (lhs: ObservationScheduler, rhs: ObservationScheduler) -> Bool {
        switch (lhs.handle, rhs.handle) {
        case let (.some(left), .some(right)):
            return left === right
        case (.none, .none):
            return false
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        guard let handle else {
            hasher.combine(0)
            return
        }
        hasher.combine(ObjectIdentifier(handle))
    }
}

public extension ObservationScheduler {
    @MainActor
    final class Handle {
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

        func cancel() {
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
public extension Observable where Self: AnyObject {
    func observeDebounced<Value>(
        _ keyPath: KeyPath<Self, Value>,
        debounce delay: ContinuousClock.Duration? = nil,
        initial: Bool = false,
        onChange: @escaping ObservationScheduler.ChangeHandler
    ) -> ObservationScheduler {
        ObservationScheduler { [weak self] in
            guard let self else { return }
            _ = self[keyPath: keyPath]
        }
        .debounce(delay)
        .initial(initial)
        .onChange(onChange)
    }

    func callAsFunction<Value>(
        _ keyPath: KeyPath<Self, Value>,
        debounce delay: ContinuousClock.Duration? = nil,
        initial: Bool = false,
        onChange: @escaping ObservationScheduler.ChangeHandler
    ) -> ObservationScheduler {
        observeDebounced(
            keyPath,
            debounce: delay,
            initial: initial,
            onChange: onChange
        )
    }
}
