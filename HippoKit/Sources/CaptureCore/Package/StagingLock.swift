import Foundation
import Darwin

/// Exclusive `flock` on `staging/<capture-id>.lock` (ruling R2). The writer holds it from before the
/// staging directory exists until after the final rename; the reconciler only deletes staging it can lock.
public struct StagingLock: Sendable {
    let fd: Int32
    let url: URL

    /// Blocks until the lock is held.
    public static func acquire(at url: URL) throws -> StagingLock {
        guard let lock = try lock(at: url, blocking: true) else { throw CaptureError.io("lock failed") }
        return lock
    }

    /// Returns nil if another holder owns the lock.
    public static func tryAcquire(at url: URL) throws -> StagingLock? {
        try lock(at: url, blocking: false)
    }

    private static func lock(at url: URL, blocking: Bool) throws -> StagingLock? {
        while true {
            let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw CaptureError.io("open lock failed: errno \(errno)") }
            var result: Int32
            repeat { result = flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
            guard result == 0 else {
                let code = errno
                close(fd)
                if !blocking && code == EWOULDBLOCK { return nil }
                throw CaptureError.io("lock failed: errno \(code)")
            }
            // The reconciler unlinks lock files it acquires. If that happened while we waited, the inode we
            // locked is no longer at the path and guards nothing, so start over with a fresh file.
            var held = stat(), current = stat()
            if fstat(fd, &held) == 0, stat(url.path, &current) == 0,
               held.st_dev == current.st_dev, held.st_ino == current.st_ino {
                return StagingLock(fd: fd, url: url)
            }
            close(fd)
        }
    }

    /// Unlink while still holding the lock, then close (which releases it).
    public func release() {
        unlink(url.path)
        close(fd)
    }
}
