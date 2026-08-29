import AppKit
import CFontProvider
import CoreGraphics
import Foundation

/// Runs the provider inside an NSApplication, so it can own real windows.
///
/// The agent has no bundle, no Dock icon and no menu bar — `.accessory` keeps it
/// that way. What it gains is the ability to draw its own interface instead of
/// borrowing Script Editor's, which is what `osascript display dialog` amounts
/// to: the dialog is attributed to whichever process ran the script, its layout
/// is not ours to control, and its text is silently clamped.
///
/// The font hook is registered on the main runloop in the *common* modes before
/// NSApplication takes it over, so requests keep being answered while a window
/// of ours is on screen. Registered in the default mode alone, a font request
/// arriving during a modal session or a menu tracking loop would stall the
/// asking application until the user clicked something.
enum AppHost {

    /// Whether this process can draw at all.
    ///
    /// The agent is normally bootstrapped into the user's Aqua session and can.
    /// Run by hand over ssh, or under a launchd domain with no window server, it
    /// cannot — and touching NSApplication there is fatal rather than merely
    /// useless. The provider itself is perfectly happy headless, so that case
    /// falls back to the plain runloop and simply says nothing.
    static var hasWindowServer: Bool {
        CGSessionCopyCurrentDictionary() != nil
    }

    static func run(provider: Provider) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        provider.attach()
        app.run()
        exit(0)
    }
}
