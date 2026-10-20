//
//  FluidMenuBarExtraWindow.swift
//  FluidMenuBarExtra
//
//  Created by Lukas Romsicki on 2022-12-16.
//  Copyright © 2022 Lukas Romsicki.
//

import AppKit
import SwiftUI

/// A custom window configured to behave as closely to an `NSMenu` as possible.
///
/// `FluidMenuBarExtraWindow` listens for changes to the size of its content and
/// automatically adjusts its frame to match.
final class FluidMenuBarExtraWindow<Content: View>: NSPanel {
    private let content: () -> Content

    private lazy var visualEffectView: NSView = {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = 16
            view.translatesAutoresizingMaskIntoConstraints = true
            return view
        } else {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.state = .active
            view.material = .popover
            view.translatesAutoresizingMaskIntoConstraints = true
            return view
        }
    }()

    private var rootView: some View {
        content()
            .modifier(RootViewModifier(windowTitle: title))
            .onSizeUpdate { [weak self] size in
                self?.contentSizeDidUpdate(to: size)
            }
    }

    private lazy var hostingView: NSHostingView<some View> = {
        let view = NSHostingView(rootView: rootView)
        // Disable NSHostingView's default automatic sizing behavior.
        if #available(macOS 13.0, *) {
            view.sizingOptions = []
        }
        view.isVerticalContentSizeConstraintActive = false
        view.isHorizontalContentSizeConstraintActive = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(title: String, content: @escaping () -> Content) {
        self.content = content

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = title

        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false

        if #available(macOS 26.0, *) {
            backgroundColor = .clear
        }

        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        animationBehavior = .none
        if #available(macOS 13.0, *) {
            collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        } else {
            collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        }
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        contentView = visualEffectView
        visualEffectView.addSubview(hostingView)
        setContentSize(hostingView.intrinsicContentSize)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor)
        ])
    }

    private func contentSizeDidUpdate(to size: CGSize) {
        // ocbar: the frame is derived when the resize is applied, not when it is reported —
        // the panel may have been placed under the status item in between (rurza fork).
        // The top-left corner stays put; the panel animates only while it is on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.frameRect(forContentRect: CGRect(origin: .zero, size: size))
            var nextFrame = PopoverPlacementPolicy.rebase(pendingFrame: target, onto: self.frame)
            if let visibleFrame = self.screen?.visibleFrame {
                nextFrame = PopoverPlacementPolicy.clampHorizontally(nextFrame, to: visibleFrame)
            }
            guard self.frame != nextFrame else { return }
            self.setFrame(nextFrame, display: true, animate: self.isVisible)
        }
    }

    // ocbar: Esc closes the panel, as it closes a menu (coder fork).
    override func cancelOperation(_ sender: Any?) {
        resignKey()
    }
}
