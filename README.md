# ObservationHelper

ObservationHelper wraps Apple's Observation framework so you can register change handlers with optional debouncing without re-implementing the same boilerplate over and over.

## Features
- Fluent scheduler API that keeps the tracking block, debouncing, and change handler in one place.
- Automatic re-registration after every change so you never forget to observe again.
- Convenience helpers for key-path based observation from any `Observable` object.

## Requirements
- Swift tools 6.2 or later
- iOS 17 / macOS 14 or later (Observation framework)

## Quick Start

```swift
import Observation
import ObservationHelper

@ObservationIgnored private var schedulers = Set<ObservationScheduler>()

func bindSettings() {
    ObservationScheduler.observe { [weak self] in
        guard let self else { return }
        _ = self.settings.isEnabled
    }
    .debounce(.milliseconds(150))
    .initial(true)
    .onChange { [weak self] in
        self?.reloadInterface()
    }
    .store(in: &schedulers)
}
```

## Boilerplate Comparison

Setting up observation manually quickly turns into a mix of `withObservationTracking`, recursive re-registration, and ad-hoc debouncing. ObservationScheduler keeps the intent obvious.

### Before (hand-rolled observation)

```swift
final class TimelineViewModel: Observable {
    private var debounceTask: Task<Void, Never>?

    func bindSettings() {
        withObservationTracking {
            _ = settings.isEnabled
        } onChange: { [weak self] in
            guard let self else { return }
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self.handleChange()
                self.bindSettings() // re-register
            }
        }
    }

    private func handleChange() {
        // Update UI...
    }
}
```

### After (ObservationScheduler)

```swift
final class TimelineViewModel: Observable {
    @ObservationIgnored private var schedulers = Set<ObservationScheduler>()

    func bindSettings() {
        ObservationScheduler.observe { [weak self] in
            guard let self else { return }
            _ = self.settings.isEnabled
        }
        .debounce(.milliseconds(150))
        .onChange { [weak self] in
            self?.handleChange()
        }
        .store(in: &schedulers)
    }

    private func handleChange() {
        // Update UI...
    }
}
```

The fluent API makes it clear what is being observed, how it is throttled, and what happens when the value changes—without any manual cancellation or explicit re-registration.

## Convenience Extensions

`Observable` types gain a `observeDebounced` helper (and a `callAsFunction` wrapper) that reads even shorter when you only need a single key path:

```swift
translationProcessor.observeDebounced(\.isTranslateTweet, debounce: .seconds(0.1)) { [weak self] in
    guard let self else { return }
    self.updateLiveTranslationToggle()
}
.store(in: &observationSchedulers)
```

## License

ObservationHelper is available under the terms of the MIT License. See the `LICENSE` file for details.

