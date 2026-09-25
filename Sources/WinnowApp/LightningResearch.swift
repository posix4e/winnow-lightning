import Foundation
import WalletCore

/// The existing TestFlight identity gets a separate Swift wallet namespace.
/// Legacy PQLN keys and files are preserved and never opened by this engine.
enum LightningResearch {
    static let bundleID = "com.btcswift.lightning"
    static let storageName = "Winnow-Lightning-SwiftV2"
    static let keychainService = "com.btcswift.lightning.swift-v2"
    static var isResearchApp: Bool { Bundle.main.bundleIdentifier == bundleID }
    static func enabled(e2e: E2EMode?) -> Bool { isResearchApp || e2e?.forcedNetwork == .regtest }
}
