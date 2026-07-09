import SwiftUI

/// The window-style popover shown when the menu bar icon is clicked.
struct MenuContentView: View {
    @EnvironmentObject private var store: VolumeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if store.disks.isEmpty && !store.isBusy {
                emptyState
            } else {
                driveList
            }

            if let error = store.lastError {
                Divider()
                errorRow(error)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.secondary)
            Text("Fibre Channel Drives")
                .font(.headline)
            Spacer()
            if store.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No Fibre Channel drives detected.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: - Drive list

    private var driveList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.disks) { disk in
                diskSection(disk)
            }

            bulkActionButton
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    /// "Unmount All" when anything is mounted (the safe-disconnect action), otherwise
    /// "Mount All" to bring every volume back.
    @ViewBuilder
    private var bulkActionButton: some View {
        if store.hasMountedVolumes {
            Button {
                store.ejectAll()
            } label: {
                Label("Unmount All (safe to disconnect)", systemImage: "eject.fill")
                    .frame(maxWidth: .infinity)
            }
        } else {
            Button {
                store.mountAll()
            } label: {
                Label("Mount All Drives", systemImage: "externaldrive.badge.plus")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func diskSection(_ disk: FCDisk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(disk.mediaName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)

            ForEach(disk.volumes) { volume in
                volumeRow(volume)
            }
        }
    }

    private func volumeRow(_ volume: FCVolume) -> some View {
        let op = store.operation(for: volume.id)
        return HStack(spacing: 10) {
            Image(systemName: volume.isMounted ? "internaldrive.fill" : "internaldrive")
                .foregroundStyle(volume.isMounted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.body)
                statusLine(for: volume, op: op)
            }
            Spacer()
            if let op {
                progressIndicator(op)
            } else {
                Toggle("", isOn: Binding(
                    get: { volume.isMounted },
                    set: { _ in store.toggle(volume) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(store.isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// Subtitle: shows the live operation phase when active, otherwise mount state + size.
    @ViewBuilder
    private func statusLine(for volume: FCVolume, op: VolumeOperation?) -> some View {
        if let op {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secs = max(0, Int(context.date.timeIntervalSince(op.started)))
                Text(hintText(for: op, seconds: secs))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(subtitle(for: volume))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func progressIndicator(_ op: VolumeOperation) -> some View {
        ProgressView().controlSize(.small)
    }

    private func hintText(for op: VolumeOperation, seconds: Int) -> String {
        let base = "\(op.verb)… \(seconds)s"
        // Xsan mounts can take up to a minute; reassure the user it isn't stuck.
        if op.kind == .mounting && seconds >= 5 {
            return "\(base) — Xsan mounts can take up to a minute"
        }
        return base
    }

    private func subtitle(for volume: FCVolume) -> String {
        let state = volume.isMounted ? "Mounted" : "Not mounted"
        guard volume.sizeBytes > 0 else { return state }
        let size = ByteCountFormatter.string(fromByteCount: volume.sizeBytes, countStyle: .file)
        return "\(state) · \(size)"
    }

    // MARK: - Error

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit SAN-Unlink", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
