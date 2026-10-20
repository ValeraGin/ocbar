//
//  FluidMenuBarExtra.swift
//  FluidMenuBarExtra
//
//  Created by Lukas Romsicki on 2022-12-17.
//  Copyright © 2022 Lukas Romsicki.
//

import AppKit
import SwiftUI

/// A class you use to create a SwiftUI menu bar extra in both SwiftUI and non-SwiftUI
/// applications.
///
/// A fluid menu bar extra is configured by initializing it once during the lifecycle of your
/// app, most commonly in your application delegate. In SwiftUI apps, use
/// `NSApplicationDelegateAdaptor` to create an application delegate in which
/// a ``FluidMenuBarExtra`` can be created.
///
/// ocbar: the status item image can change, the panel can be shown and dismissed from code,
/// and the status button and panel are exposed for the live menu probe (see VENDOR.md).
public final class FluidMenuBarExtra {
    private let statusItem: FluidMenuBarExtraStatusItem

    public init(title: String, image: NSImage?, @ViewBuilder content: @escaping () -> some View) {
        let window = FluidMenuBarExtraWindow(title: title, content: content)
        statusItem = FluidMenuBarExtraStatusItem(title: title, window: window)
        statusItem.image = image
    }

    /// The image shown in the menu bar.
    public var image: NSImage? {
        get { statusItem.image }
        set { statusItem.image = newValue }
    }

    /// Whether the status item is in the menu bar.
    public var isInserted: Bool {
        get { statusItem.isInserted }
        set { statusItem.isInserted = newValue }
    }

    /// Whether the panel is on screen.
    public var isPresented: Bool { statusItem.isPresented }

    public func present() { statusItem.present() }
    public func dismiss() { statusItem.dismiss() }
    public func toggle() { statusItem.isPresented ? statusItem.dismiss() : statusItem.present() }

    /// The status bar button and the panel itself.
    public var button: NSStatusBarButton? { statusItem.button }
    public var window: NSWindow { statusItem.window }
}
