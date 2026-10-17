import Foundation

/// Calls back when something in a folder changes (a file is created, replaced, renamed or removed).
/// The kernel tells us, so there is no polling and no cost while nothing changes. Used to notice
/// the widget skipping or flipping a card, which rewrites a file in the shared folder.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    /// Returns nil if the folder can't be watched.
    init?(directory: URL, queue: DispatchQueue = .main, coalescing: TimeInterval = 0.1, onChange: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .link],
            queue: queue
        )
        var pending = false
        source.setEventHandler {
            // An atomic save produces a burst of events; report it once.
            guard !pending else { return }
            pending = true
            queue.asyncAfter(deadline: .now() + coalescing) {
                pending = false
                onChange()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { cancel() }
}
