# ComposableWatchConnectivity
Composable WatchConnectivity is library that bridges [the Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) and [WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity) framework.
* [Japanese Guide](#japanese-guide)
* [Example](#example)
* [Basic Usage](#basic-usage)
* [Installation](#installation)

## Japanese Guide
Motivation & Sample
* https://zenn.dev/ueeek/articles/20241215tca_watchconnectivity

## Example
Check out the [Demo](https://github.com/Ueeek/ComposableWatchConnectivitySample) to see how to use this library.

## Basic Usage
To use ComposableWatchConnectivity in your application, you can add an action to your domain that represents all of the actions the WacthConnectivityClient can emit via the `WCSessionDelegate` methods:
```swift
import ComposableWatchConnectivity

enum Action {
    case watchConnectivity(WatchConnectivityClient.Action)
    // Other actions:
    ...
}
```

The `WatchConnectivityClient.Action` enum holds a case for each delegate method of `WCSessionDelegate`,
such as `activationDidCompleteWith(:)`, `didReceiveMessage(:)`, `didReceiveUserInfo(:)` and so on.

`WatchConnectivityClient` is declared as `DependencyClient`, so you can access it easily
```swift
    @DependencyClient(\.watchConnectivity) var watchConnectivity
```

We need to activate the Client and subscribe the action they emit.
```swift
    await watchConnectivity.activate()
    await withTaskGroup(of: Void.self) { group in
        await withTaskCancellation(id: CancelID.watchConnectivity, cancelInFlight: true) {
            for await action in await watchClient.delegate() {
                await send(.watchConnectivity(action), animation: .default)
            }
        }
    }
```

For Sender, we can call `watchClient.sendData`
```swift
Reducer { state, action in
    switch action {
        case .sendCurrentDate:
            return .run { _ in
                if let data = try? JSONEncoder().encode(Date.now) {
                    await watchClient.sendMessage(("date", data))
                }
            }
    }
    ...
}
```
For Receiver, we can receive message via `.watchConnectivity(.didReceiveMessage)`
```swift
Reducer { state, action in
    switch action {
        case .watchConnectivity(.didReceiveMessage(let message)):
        if let data = message?["date"] as? Data,
               let receivedDate = try? JSONDecoder().decode(Date.self, from: data) {
                   // Use receivedDate
               } else {
                   // Cannot parse the data
               }
            return .none
        }
    ...
}
```

## Installation
You can add ComposableWatchConnectivity to an Xcode project by adding it as a SPM package dependency.
1. From the file menu, select Swift Packages › Add Package Dependency...
2. Enter "https://github.com/Ueeek/ComposableWatchConnectivity.git"
