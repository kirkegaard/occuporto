//
//  ContentView.swift
//  occuporto
//
//  Created by Christian Kirkegaard on 11/08/2026.
//

import SwiftUI
import AppKit

/// The content shown when the menu bar icon's window is opened. Lists all
/// listening ports owned by the current user, with an option to kill each
/// owning process.
enum ProtoFilter: String, CaseIterable, Identifiable {
    case tcp = "TCP"
    case udp = "UDP"
    case both = "Both"

    var id: String { rawValue }

    func matches(_ proto: String) -> Bool {
        switch self {
        case .tcp: return proto == "tcp"
        case .udp: return proto == "udp"
        case .both: return true
        }
    }
}

/// A single row rendered in the port list. Flattening everything (process
/// rows, group headers, group-entry rows) into one `Identifiable` enum and
/// driving a single `ForEach` inside a plain `ScrollView`/`LazyVStack` is
/// deliberate: macOS's SwiftUI `List` is backed by `NSOutlineView`, and its
/// internal diffing engine (`OutlineListCoordinator`) has proven crash-prone
/// with this kind of dynamic, grouped content (crashes observed both in
/// Xcode's preview canvas and at runtime, inside Apple's own SwiftUI/AppKit
/// code). A plain `ScrollView` sidesteps `NSOutlineView` entirely.
private enum Row: Identifiable {
    case process(PortEntry)
    case systemHeader(count: Int)
    case systemEntry(PortEntry)
    case appHeader(count: Int)
    case appEntry(PortEntry)

    var id: String {
        switch self {
        case .process(let entry): return "process-\(entry.id)"
        case .systemHeader: return "system-header"
        case .systemEntry(let entry): return "system-\(entry.id)"
        case .appHeader: return "app-header"
        case .appEntry(let entry): return "app-\(entry.id)"
        }
    }
}

struct PortListView: View {
    @State private var entries: [PortEntry]
    @State private var lastError: String?
    @State private var filter: ProtoFilter = .both
    @State private var systemExpanded = false
    @State private var appsExpanded = false
    /// Number of rows the popover is sized for. Computed once whenever the
    /// popover is opened (see `onAppear`) and then left alone — refreshing
    /// or killing a process while open updates the row contents but never
    /// this value, so the popover's height (and therefore its on-screen
    /// position) stays constant for the whole time it's open. Recomputing
    /// this on every content change was resizing the popover, which —
    /// especially with "Automatically hide and show the menu bar" enabled
    /// — could leave the cursor at the screen edge and cause macOS to
    /// reveal/hide the menu bar, visibly shifting the whole window.
    @State private var lockedRowCount = 1
    @Environment(\.colorScheme) private var colorScheme

    /// Height of a single row, used to size the list so at least
    /// `minVisibleRows` are visible before scrolling kicks in.
    private let rowHeight: CGFloat = 52
    private let minVisibleRows = 10

    /// Designated initializer. `previewEntries` lets `#Preview` (and
    /// tests) supply sample data directly instead of going through
    /// `PortScanner.scan()`, which talks to live system processes and
    /// isn't something we want to run implicitly inside Xcode's preview
    /// canvas.
    init(previewEntries: [PortEntry] = []) {
        _entries = State(initialValue: previewEntries)
    }

    private var filteredEntries: [PortEntry] {
        entries.filter { filter.matches($0.proto) }
    }

    private var processEntries: [PortEntry] {
        filteredEntries.filter { !$0.isKnownApp && !$0.isSystemProcess }
    }

    private var appEntries: [PortEntry] {
        filteredEntries.filter { $0.isKnownApp }
    }

    private var systemEntries: [PortEntry] {
        filteredEntries.filter { $0.isSystemProcess }
    }

    /// The flattened row list actually rendered by `List`. See `Row`.
    private var rows: [Row] {
        var rows: [Row] = processEntries.map { .process($0) }

        if !systemEntries.isEmpty {
            rows.append(.systemHeader(count: systemEntries.count))
            if systemExpanded {
                rows.append(contentsOf: systemEntries.map { .systemEntry($0) })
            }
        }

        if !appEntries.isEmpty {
            rows.append(.appHeader(count: appEntries.count))
            if appsExpanded {
                rows.append(contentsOf: appEntries.map { .appEntry($0) })
            }
        }

        return rows
    }

    /// Dark mode uses a near-black background (#131415) to match the
    /// requested look, rather than the lighter default system material.
    /// Light mode keeps the standard translucent material.
    private var backgroundStyle: AnyShapeStyle {
        colorScheme == .dark ? AnyShapeStyle(Color(hex: 0x131415)) : AnyShapeStyle(.regularMaterial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            filterPicker

            Divider()

            if filteredEntries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No listening ports found")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 8)

                        ForEach(rows) { row in
                            rowView(for: row)
                        }
                    }
                }
                // Fixed for the lifetime of this popover session — see
                // `lockedRowCount`'s doc comment for why this doesn't just
                // track `rows.count` directly.
                .frame(height: 8 + rowHeight * CGFloat(lockedRowCount))
            }

            Divider()

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.caption)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .frame(width: 360)
        .background(backgroundStyle)
        .onAppear {
            guard !isRunningInPreview else { return }
            refresh()
            lockedRowCount = min(max(rows.count, 1), minVisibleRows)
        }
    }

    @ViewBuilder
    private func rowView(for row: Row) -> some View {
        switch row {
        case .process(let entry), .systemEntry(let entry), .appEntry(let entry):
            PortRow(entry: entry, onKill: { kill(entry) })
        case .systemHeader(let count):
            CollapsibleGroupHeader(
                title: "System",
                systemImage: "gearshape.fill",
                count: count,
                isExpanded: $systemExpanded
            )
        case .appHeader(let count):
            CollapsibleGroupHeader(
                title: "Apps",
                systemImage: "square.grid.2x2.fill",
                count: count,
                isExpanded: $appsExpanded
            )
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Occuporto")
                .font(.headline)
            Spacer()
            Text("\(processEntries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
    }

    private var filterPicker: some View {
        Picker("", selection: $filter) {
            ForEach(ProtoFilter.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func refresh() {
        entries = PortScanner.scan()
    }

    private func kill(_ entry: PortEntry) {
        PortScanner.terminate(pid: entry.pid)
        // Give the process a brief moment to exit before re-scanning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut(duration: 0.2)) { refresh() }
        }
    }
}

/// True when running inside Xcode's preview canvas, so we can skip live
/// system calls (`PortScanner.scan()`) that don't make sense there.
private var isRunningInPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

private struct CollapsibleGroupHeader: View {
    let title: String
    let systemImage: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(title) (\(count))")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct PortRow: View {
    let entry: PortEntry
    let onKill: () -> Void
    @State private var isHovering = false

    /// Full, untruncated path shown as a tooltip on hover, preferring the
    /// process's working directory (what the truncated path in the row is
    /// derived from) and falling back to the executable path.
    private var fullPathTooltip: String {
        if let workingDirectory = entry.workingDirectory, let executablePath = entry.executablePath {
            return "\(workingDirectory)\n\(executablePath)"
        }
        return entry.workingDirectory ?? entry.executablePath ?? "Unknown location"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.processName)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(verbatim: ":\(entry.port)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(entry.proto.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }

                if let path = entry.truncatedPath {
                    Label {
                        Text(path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } icon: {
                        Image(systemName: "folder")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button(action: onKill) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isHovering ? Color.red : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Kill process \(entry.pid)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .help(fullPathTooltip)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#Preview {
    PortListView(previewEntries: [
        PortEntry(
            id: "1",
            pid: 111,
            processName: "node",
            port: 3000,
            proto: "tcp",
            executablePath: "/opt/homebrew/bin/node",
            workingDirectory: "/Users/christian/Development/omnigame/sites"
        ),
        PortEntry(
            id: "2",
            pid: 222,
            processName: "ollama",
            port: 11434,
            proto: "tcp",
            executablePath: "/opt/homebrew/Cellar/ollama/libexec/ollama",
            workingDirectory: "/opt/homebrew/var"
        ),
        PortEntry(
            id: "3",
            pid: 333,
            processName: "Spotify",
            port: 57621,
            proto: "tcp",
            executablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify",
            workingDirectory: nil
        ),
        PortEntry(
            id: "4",
            pid: 444,
            processName: "reportd",
            port: 5353,
            proto: "udp",
            executablePath: "/usr/libexec/reportd",
            workingDirectory: nil
        )
    ])
}

private extension Color {
    /// Convenience initializer for a solid RGB color from a hex literal,
    /// e.g. `Color(hex: 0x131415)`.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
