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
    private var resizeGeneration = 0

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
            .removeDuplicates()
            .sink { [weak self] expanded in self?.resizePanel(expanded: expanded) }
            .store(in: &cancellables)

        store.$measuredBodyHeight
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.store.expanded == true else { return }
                self?.resizePanel(expanded: true)
            }
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
        updateScreenGeometry()
        resizePanel(expanded: store.expanded, animated: false)
    }

    private func updateScreenGeometry() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        store.notchGeometry = NotchGeometry(screen: screen)
    }

    private func createPanel() {
        updateScreenGeometry()
        let panel = NotchPanel(
            contentRect: store.notchGeometry.panelFrame(expanded: false, bodyHeight: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // isFloatingPanel resets level to .floating, so set our level afterwards.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.title = "Orca Island"
        panel.titlebarAppearsTransparent = true
        let hosting = NotchHostingView(rootView: OverlayView(store: store))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        resizePanel(expanded: false, animated: false)
        panel.orderFrontRegardless()
    }

    private func resizePanel(expanded: Bool, animated: Bool = true) {
        guard let panel else { return }
        resizeGeneration += 1
        let generation = resizeGeneration
        let frame = store.notchGeometry.panelFrame(expanded: expanded, bodyHeight: store.measuredBodyHeight)
        let reducesCanvas = frame.width < panel.frame.width || frame.height < panel.frame.height
        if animated && reducesCanvas {
            // Keep the outgoing content visible until the inner shape settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                guard let self, self.resizeGeneration == generation else { return }
                self.panel?.setFrame(frame, display: true, animate: false)
            }
        } else {
            // Enlarge before @Published updates SwiftUI; the outer canvas never animates.
            panel.setFrame(frame, display: true, animate: false)
        }
    }
}
