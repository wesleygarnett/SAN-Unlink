import Foundation

/// A mountable volume that lives on a Fibre Channel (SANlink) device.
struct FCVolume: Identifiable, Hashable {
    /// BSD identifier of the volume, e.g. "disk4s2".
    let id: String
    /// BSD identifier of the whole disk this volume belongs to, e.g. "disk4".
    let wholeDiskID: String
    /// Human-readable volume name, falling back to the BSD id when unnamed.
    let name: String
    /// Filesystem mount point, or `nil` when the volume is not mounted.
    let mountPoint: String?
    /// Volume size in bytes (0 when unknown).
    let sizeBytes: Int64

    var isMounted: Bool { mountPoint != nil }

    /// `/dev/diskXsY` node used by `diskutil`.
    var deviceNode: String { "/dev/\(id)" }
}

/// A whole Fibre Channel disk and the volumes it exposes.
struct FCDisk: Identifiable, Hashable {
    /// Whole-disk BSD identifier, e.g. "disk4".
    let id: String
    /// Media / product name reported by `diskutil` (e.g. "Promise VTrak").
    let mediaName: String
    /// Total media size in bytes.
    let sizeBytes: Int64
    /// Mountable volumes carried by this disk.
    var volumes: [FCVolume]

    var deviceNode: String { "/dev/\(id)" }

    /// True when at least one volume on the disk is currently mounted.
    var hasMountedVolume: Bool { volumes.contains(where: \.isMounted) }
}
