//
//  FluidMenuBarExtraStatusItem.swift
//  FluidMenuBarExtra
//
//  Created by Lukas Romsicki on 2022-12-17.
//  Copyright © 2022 Lukas Romsicki.
//

import AppKit
import SwiftUI

/// An individual element displayed in the system menu bar that displays a window
/// when triggered.
final class FluidMenuBarExtraStatusItem: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let statusItem: NSStatusItem

    private var localEventMonitor: EventMonitor?
    private var globalEventMonitor: EventMonitor?

    init(title: String, window: NSWindow) {
        self.window = window

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        super.init()

        statusItem.button?.setAccessibilityTitle(title)

        localEventMonitor = LocalEventMonitor(mask: [.leftMouseDown]) { [weak self] event in
            if let button = self?.statusItem.button, event.window == button.window, !event.modifierFlags.contains(.command) {
                self?.didPressStatusBarButton()

                // Stop propagating the event so that the button remains highlighted.
                return nil
            }

            return event
        }

        globalEventMonitor = GlobalEventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let window = self?.window, window.isKeyWindow {
                // Resign key window status if a external non-activating event is triggered,
                // such as other system status bar menus.
                window.resignKey()
            }
        }

        window.delegate = self
        localEventMonitor?.start()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    var button: NSStatusBarButton? { statusItem.button }

    var image: NSImage? {
        get { statusItem.button?.image }
        set { statusItem.button?.image = newValue }
    }

    var isInserted: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    /// On screen and not fading out.
    var isPresented: Bool { window.isVisible && !dismissing }

    private var dismissing = false

    private func didPressStatusBarButton() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        guard !isPresented else { return }
        dismissing = false
        window.alphaValue = 1
        setWindowPosition()

        // Tells the system to persist the menu bar in full screen mode.
        DistributedNotificationCenter.default().post(name: .beginMenuTracking, object: nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        globalEventMonitor?.start()
        setButtonHighlighted(to: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        globalEventMonitor?.stop()
        dismiss()
    }

    func dismiss() {
        guard window.isVisible, !dismissing else { return }
        dismissing = true

        // Tells the system to cancel persisting the menu bar in full screen mode.
        DistributedNotificationCenter.default().post(name: .endMenuTracking, object: nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            window.animator().alphaValue = 0

        } completionHandler: { [weak self] in
            // Shown again while fading out: leave it on screen.
            guard let self, self.dismissing else { return }
            self.dismissing = false
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.setButtonHighlighted(to: false)
        }
    }

    private func setButtonHighlighted(to highlight: Bool) {
        statusItem.button?.highlight(highlight)
    }

    // ocbar: placement from the rurza fork (PopoverPlacementPolicy) — compares with the
    // screen's maxX, so the panel stays on the right display in multi-display setups.
    private func setWindowPosition() {
        let buttonWindow = statusItem.button?.window
        guard let screen = buttonWindow?.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let topLeft = PopoverPlacementPolicy.popoverTopLeft(
            statusItemFrame: buttonWindow?.frame,
            popoverWidth: window.frame.width,
            screenVisibleFrame: screen.visibleFrame,
            borderSize: Metrics.windowBorderSize
        )
        window.setFrameTopLeftPoint(topLeft)
    }
}

private extension Notification.Name {
    static let beginMenuTracking = Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification")
    static let endMenuTracking = Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification")
}

private enum Metrics {
    static let windowBorderSize: CGFloat = 2
}
