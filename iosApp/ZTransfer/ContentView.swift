import Foundation
import SwiftUI

struct ContentView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Z传")
                .font(.largeTitle.bold())

            Text("iOS 共享工程已就绪")
                .foregroundStyle(.secondary)

            Text("v\(version)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
