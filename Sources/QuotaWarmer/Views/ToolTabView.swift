import SwiftUI

struct ToolTabView: View {
    @ObservedObject var toolState: ToolState
    let onActivate: () -> Void

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private var accent: Color { DS.C.accent(toolState.tool) }

    private enum Phase {
        case warming
        case active(remaining: TimeInterval)
        case expired
    }

    private var phase: Phase {
        if toolState.isWarming { return .warming }
        if let r = toolState.timeUntilReset, r > 0 { return .active(remaining: r) }
        return .expired
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(DS.C.border)
                windowSection
                Divider().background(DS.C.border)
                autoWarmRow
                Divider().background(DS.C.border)
                actionSection
                Divider().background(DS.C.border)
                logSection
            }
        }
        .background(DS.C.bg)
        .onReceive(ticker) { t in now = t }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(toolState.tool == .claude ? "ClaudeCode" : "Codex")
                .resizable().scaledToFit()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(toolState.tool.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                if let last = toolState.lastActivity {
                    Text("last log " + relativeTime(last))
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textMuted)
                } else {
                    Text("no activity detected")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textMuted)
                }
            }

            Spacer()
            statusPill
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
            Text(statusLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(statusColor.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(statusColor.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Window section

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("WINDOW").dsLabel()
                Spacer()
                phaseLabel
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.C.surface)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barGradient)
                        .frame(width: max(geo.size.width * toolState.windowProgress, 0), height: 4)
                        .animation(.easeInOut(duration: 1), value: toolState.windowProgress)
                    ForEach([1, 2, 3, 4], id: \.self) { h in
                        Rectangle()
                            .fill(DS.C.bg.opacity(0.7))
                            .frame(width: 1, height: 4)
                            .offset(x: geo.size.width * Double(h) / 5.0 - 0.5)
                    }
                }
            }
            .frame(height: 4)

            HStack {
                ForEach(["0h", "1h", "2h", "3h", "4h", "5h"], id: \.self) { t in
                    Text(t)
                        .font(.system(size: 8))
                        .foregroundStyle(DS.C.textMuted)
                    if t != "5h" { Spacer() }
                }
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch phase {
        case .warming:
            Text("activating…")
                .font(DS.mono(9)).foregroundStyle(DS.C.blue)
        case .active(let r):
            Text(formatCountdown(r))
                .font(DS.mono(11, weight: .semibold))
                .foregroundStyle(timeColor(r))
            + Text(" left")
                .font(DS.mono(9)).foregroundStyle(DS.C.textMuted)
        case .expired:
            Text(toolState.lastActivity == nil ? "not started" : "expired")
                .font(DS.mono(9)).foregroundStyle(DS.C.textMuted)
        }
    }

    // MARK: - Auto-warm row

    private var autoWarmRow: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-Warm")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.C.text)
                Text("Send 'hi' automatically at window reset")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
            Toggle("", isOn: $toolState.autoWarm)
                .toggleStyle(.switch)
                .scaleEffect(0.72)
                .tint(accent)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm + 2)
    }

    // MARK: - Action section

    private var actionSection: some View {
        Group {
            switch phase {
            case .warming:    warmingState
            case .active(let r): activeState(remaining: r)
            case .expired:    expiredState
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private var warmingState: some View {
        HStack(spacing: DS.Space.sm) {
            ProgressView().scaleEffect(0.65).tint(DS.C.blue)
            Text("Sending warmup message…")
                .font(.system(size: 11))
                .foregroundStyle(DS.C.textSub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.md)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.md))
        .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border))
    }

    private func activeState(remaining: TimeInterval) -> some View {
        VStack(spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: toolState.autoWarm ? "clock.badge.checkmark.fill" : "clock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.C.green)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolState.autoWarm ? "Auto-trigger scheduled" : "Window active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.C.text)
                    Group {
                        if toolState.autoWarm, let exp = toolState.windowExpires {
                            Text("Next at \(formatWallTime(exp))  ·  \(formatCountdown(remaining)) away")
                        } else {
                            Text("\(formatCountdown(remaining)) until expiry")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textSub)
                }
                Spacer()
            }
            .padding(DS.Space.md)
            .background(DS.C.green.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.R.md))
            .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.green.opacity(0.12)))

            Button(action: onActivate) {
                Label("Force Re-trigger  (resets clock)", systemImage: "bolt")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.C.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.sm))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border))
            }
            .buttonStyle(.plain)

            if let err = toolState.errorMessage {
                Text(err).font(.system(size: 10))
                    .foregroundStyle(DS.C.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var expiredState: some View {
        VStack(spacing: DS.Space.sm) {
            Button(action: onActivate) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    Text("Activate Window").font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(accent, in: RoundedRectangle(cornerRadius: DS.R.md))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if let err = toolState.errorMessage {
                Text(err).font(.system(size: 10))
                    .foregroundStyle(DS.C.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Log section

    private var logSection: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) { toolState.isLogExpanded.toggle() }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(DS.C.textMuted)
                    Text("PROMPT LOG").dsLabel()
                    if !toolState.warmupLogs.isEmpty {
                        Text("\(toolState.warmupLogs.count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Image(systemName: toolState.isLogExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm + 2)
            }
            .buttonStyle(.plain)

            if toolState.isLogExpanded {
                logContent.transition(.opacity)
            }
        }
    }

    private var logContent: some View {
        Group {
            if toolState.warmupLogs.isEmpty {
                Text("No warmups triggered yet")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(Color.black.opacity(0.55))
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(toolState.warmupLogs) { entry in
                            LogEntryView(entry: entry, accent: accent)
                        }
                    }
                    .padding(DS.Space.md)
                }
                .frame(maxHeight: 170)
                .background(Color.black.opacity(0.75))
            }
        }
    }

    // MARK: - Helpers

    private var statusLabel: String {
        switch phase {
        case .warming: return "WARMING"
        case .active:  return "ACTIVE"
        case .expired: return "IDLE"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .warming: return DS.C.blue
        case .active:  return DS.C.green
        case .expired: return DS.C.textMuted
        }
    }

    private var barGradient: LinearGradient {
        let p = toolState.windowProgress
        let c: Color = p > 0.8 ? DS.C.red : p > 0.5 ? DS.C.yellow : accent
        return LinearGradient(colors: [c.opacity(0.5), c], startPoint: .leading, endPoint: .trailing)
    }

    private func timeColor(_ r: TimeInterval) -> Color {
        r > 3600 ? DS.C.text : r > 1800 ? DS.C.yellow : DS.C.red
    }

    private func formatCountdown(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, sec)
    }

    private func formatWallTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private func relativeTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h \((s % 3600) / 60)m ago"
    }
}

// MARK: - Log entry

struct LogEntryView: View {
    let entry: WarmupLog
    let accent: Color

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(Self.fmt.string(from: entry.timestamp))
                    .font(DS.mono(8)).foregroundStyle(DS.C.textMuted)
                Text("$")
                    .font(DS.mono(9, weight: .bold)).foregroundStyle(accent.opacity(0.5))
                Text(entry.command)
                    .font(DS.mono(10, weight: .bold)).foregroundStyle(accent)
            }
            Text(entry.output)
                .font(DS.mono(9))
                .foregroundStyle(Color.white.opacity(0.60))
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(DS.Space.sm)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: DS.R.sm))
    }
}
