import SwiftUI

struct OverlayView: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        Group {
            if store.expanded {
                expandedView
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { store.expanded = true }
                } label: {
                    compactView
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开 Orca 会话")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.clear)
    }

    private var compactView: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(store.currentSession?.tint ?? .gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.currentSession?.workspaceName ?? "Orca Island")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(store.currentSession?.title ?? "等待会话")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(store.sessions.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.black.opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .help(store.currentSession?.title ?? "展开 Orca 会话")
    }

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Orca Island")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(store.workspaceGroups.count) 个工作区 · \(store.sessions.count) 个对话")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { store.expanded = false }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起 Orca 会话")
            }

            if store.sessions.isEmpty {
                Text("等待 Orca 状态事件…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(store.workspaceGroups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.white.opacity(0.5))
                                    Text(group.name)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    Text("\(group.sessions.count)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Spacer()
                                }
                                .font(.system(size: 12))
                                .help(group.id)

                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
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
            .padding(.leading, 20)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(session.title)\n\(session.workspaceName) · \(session.displayState)")
        .accessibilityLabel("\(session.workspaceName)，\(session.title)，\(session.displayState)")
    }
}
