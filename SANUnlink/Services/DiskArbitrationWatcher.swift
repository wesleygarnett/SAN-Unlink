import Foundation
import DiskArbitration

/// Watches Disk Arbitration for disk appear / disappear / description changes and
/// invokes `onChange` (on the main queue) so the UI can refresh. Registration runs
/// on a dedicated background run loop to avoid blocking the main thread.
final class DiskArbitrationWatcher {

    /// Called on the main queue whenever the set of disks may have changed.
    var onChange: (() -> Void)?

    private var session: DASession?
    private var runLoop: CFRunLoop?

    func start() {
        let workerThread = Thread { [weak self] in
            guard let self else { return }

            guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
            self.session = session

            let context = Unmanaged.passUnretained(self).toOpaque()

            DARegisterDiskAppearedCallback(
                session, nil, DiskArbitrationWatcher.diskAppeared, context)
            DARegisterDiskDisappearedCallback(
                session, nil, DiskArbitrationWatcher.diskDisappeared, context)
            DARegisterDiskDescriptionChangedCallback(
                session, nil, nil, DiskArbitrationWatcher.diskChanged, context)

            guard let currentRunLoop = CFRunLoopGetCurrent() else { return }
            self.runLoop = currentRunLoop
            DASessionScheduleWithRunLoop(session, currentRunLoop, CFRunLoopMode.defaultMode.rawValue)

            CFRunLoopRun()

            DASessionUnscheduleFromRunLoop(session, currentRunLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        workerThread.name = "com.sanunlink.disk-arbitration"
        workerThread.start()
    }

    func stop() {
        if let runLoop { CFRunLoopStop(runLoop) }
        session = nil
        runLoop = nil
    }

    fileprivate func notifyChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    // MARK: - C callbacks

    private static let diskAppeared: DADiskAppearedCallback = { _, context in
        guard let context else { return }
        Unmanaged<DiskArbitrationWatcher>.fromOpaque(context).takeUnretainedValue().notifyChanged()
    }

    private static let diskDisappeared: DADiskDisappearedCallback = { _, context in
        guard let context else { return }
        Unmanaged<DiskArbitrationWatcher>.fromOpaque(context).takeUnretainedValue().notifyChanged()
    }

    private static let diskChanged: DADiskDescriptionChangedCallback = { _, _, context in
        guard let context else { return }
        Unmanaged<DiskArbitrationWatcher>.fromOpaque(context).takeUnretainedValue().notifyChanged()
    }
}
