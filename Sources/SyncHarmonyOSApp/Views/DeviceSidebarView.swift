//
//  File:    DeviceSidebarView.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: MIT
//

// DeviceSidebarView.swift — device picker and storage volumes.

import SwiftUI
import SyncHarmonyCore

struct DeviceSidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            deviceSection
            storageSection
            connectionSection
        }
        .listStyle(.sidebar)
    }

    private var deviceSection: some View {
        Section("设备") {
            if model.devices.isEmpty {
                Label("未发现设备", systemImage: "iphone.slash")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.devices) { device in
                    DeviceRow(device: device,
                              connected: isConnected(device),
                              onConnect: { model.connect(to: device) })
                }
            }
        }
    }

    private var storageSection: some View {
        Section("存储卷") {
            ForEach(model.storages) { storage in
                StorageRow(storage: storage,
                           selected: storage.storageID == model.selectedStorageID,
                           onSelect: { model.selectStorage(storage.storageID) })
            }
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                model.disconnect()
            } label: {
                Label("断开连接", systemImage: "bolt.slash")
            }
            .disabled(model.connection != .connected)
        }
    }

    private func isConnected(_ device: MTPUSBDeviceInfo) -> Bool {
        model.connection == .connected && !model.storages.isEmpty
    }
}

private struct DeviceRow: View {
    let device: MTPUSBDeviceInfo
    let connected: Bool
    let onConnect: () -> Void

    private var subtitle: String {
        String(format: "%04X:%04X %@", device.vendorID, device.productID, device.serialNumber)
    }

    var body: some View {
        Button(action: onConnect) {
            HStack {
                Image(systemName: "iphone.smartphone")
                VStack(alignment: .leading) {
                    Text(device.displayName)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if connected {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct StorageRow: View {
    let storage: MTPStorage
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: "internaldrive")
                VStack(alignment: .leading) {
                    Text(storage.displayName)
                    // Devices report 32-bit capacities; values above
                    // 4 GiB cap out — show free space without totals.
                    Text("剩余 \(ByteCount.format(storage.freeSpaceInBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
