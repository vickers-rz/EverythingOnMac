import Foundation
import EverythingOnMacCore

#if os(macOS)
import SwiftUI
import AppKit

@main
struct EverythingOnMacApp: App {
    @StateObject private var viewModel = SearchViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

#else
@main
struct EverythingOnMacCLI {
    static func main() {
        print("EverythingOnMac is a native macOS app. Build and run on macOS to use UI.")
    }
}
#endif
