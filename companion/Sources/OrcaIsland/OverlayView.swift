import SwiftUI
import Combine

private struct IslandBodyHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct OverlayView: View {
    @ObservedObject var store: IslandStore

    private var geometry: NotchGeometry { store.notchGeometry }
    private var workingCount: Int { store.sessions.values.filter { $0.state == "working" }.count }
    private var attentionCount: Int {
        store.sessions.values.filter { $0.state == "waiting" || $0.state == "blocked" }.count
    }
    private var statusColor: Color {
        if attentionCount > 0 { return .orange }
        return workingCount > 0 ? .cyan : (store.sessions.isEmpty ? .gray : .green)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                store.expanded.toggle()
            } label: {
                notchBar
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.expanded ? "收起 Orca 会话" : "展开 Orca 会话")
            .help("点击刘海两侧\(store.expanded ? "收起" : "展开") · \(workingCount) 个工作中 · \(attentionCount) 个待处理 · \(store.sessions.count) 个对话")

            if store.expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        measuredContent
                    }
                    .frame(height: store.visibleBodyHeight)
                    .onReceive(store.$recentCompletionID.removeDuplicates()) { id in
                        if let id {
                            DispatchQueue.main.async {
                                withAnimation { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: store.expanded ? geometry.expandedWidth : geometry.collapsedWidth)
        .background(Color.black)
        .clipShape(NotchSilhouette(bottomRadius: store.expanded ? 20 : 13))
        .background(alignment: .top) {
            if !store.expanded {
                // Measure the next layout without giving the closed window a large hit region.
                measuredContent.hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onPreferenceChange(IslandBodyHeight.self) { height in
            let rounded = ceil(height)
            if rounded > 0 && abs(rounded - store.measuredBodyHeight) > 0.5 {
                store.measuredBodyHeight = rounded
            }
        }
    }

    private var notchBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .foregroundStyle(statusColor)
                Text("Orca")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)

            // The physical camera occupies this area. Keep all labels in the wings.
            Color.clear.frame(width: geometry.cameraWidth, height: geometry.topBarHeight)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                Image(systemName: attentionCount > 0 ? "exclamationmark.circle.fill" :
                      workingCount > 0 ? "circle.dotted" : "checkmark.circle")
                    .foregroundStyle(statusColor)
                Text("\(store.sessions.count)")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                if store.expanded {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
        }
        .frame(height: geometry.topBarHeight)
        .contentShape(Rectangle())
    }

    private var measuredContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(store.workspaceGroups.count) 个工作区 · \(store.sessions.count) 个对话")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))

            if store.sessions.isEmpty {
                Text("等待 Orca 会话")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(store.workspaceGroups) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: "folder")
                                .foregroundStyle(.white.opacity(0.5))
                            Text(group.name)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(group.sessions.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12))
                        .help(group.name)

                        ForEach(group.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 7)
        .padding(.bottom, 16)
        .frame(width: geometry.expandedWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: IslandBodyHeight.self, value: proxy.size.height)
        })
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        Button {
            TerminalSwitcher.switchTo(session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(session.tint)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(session.displayState)
                    .font(.system(size: 10))
                    .foregroundStyle(session.tint)
                    .padding(.top, 2)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 3)
            }
            .padding(.leading, 18)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if session.id == store.recentCompletionID {
                RoundedRectangle(cornerRadius: 6).fill(.green.opacity(0.12))
            }
        }
        .id(session.id)
        .help("\(session.title)\n\(session.workspaceName) · \(session.displayState)")
        .accessibilityLabel("\(session.workspaceName)，\(session.title)，\(session.displayState)")
    }
}
