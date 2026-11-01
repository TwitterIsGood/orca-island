import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = IslandStore()
    private var panel: NSPanel?
    private var server: LocalHTTPServer?
    private var poller: OrcaStatusPoller?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()

        do {
            server = try LocalHTTPServer(port: 17777) { [weak self] body in
                DispatchQueue.main.async {
                    guard let event = try? JSONDecoder().decode(IslandEvent.self, from: body) else { return }
                    self?.store.ingest(event)
                }
            }
            server?.start()
        } catch {
            NSLog("Orca Island HTTP server failed: \(error.localizedDescription)")
        }

        poller = OrcaStatusPoller { [weak self] events in
            self?.store.replaceFromPoll(events)
        }
        poller?.start()

        store.$expanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizePanel() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionPanel),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        poller?.stop()
    }

    @objc private func repositionPanel() {
        resizePanel(animated: false)
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.title = "Orca Island"
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: OverlayView(store: store))
        self.panel = panel
        resizePanel(animated: false)
        panel.orderFrontRegardless()
    }

    private func resizePanel(animated: Bool = true) {
        guard let panel else { return }
        let size = store.expanded ? NSSize(width: 440, height: 340) : NSSize(width: 340, height: 46)
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height - 8
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true, animate: animated)
        panel.orderFrontRegardless()
    }
}
