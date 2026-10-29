import Foundation
import Darwin

public struct ProcessOutcome: Sendable {
    /// Exit code, or the signal number when `signaled`.
    public var status: Int32
    public var signaled: Bool
    public var stdout: Data
    public var stderr: Data
    public var stdoutTruncated: Bool
    public var timedOut: Bool
    public var cancelled: Bool
    public var pid: pid_t
    public var durationMs: Double
}

public enum ProcessError: Error, Equatable, Sendable {
    case spawnFailed(errno: Int32)
    case pipeFailed(errno: Int32)
}

/// Runs a child process directly (no shell) with a caller-chosen environment.
///
/// Lessons from Spikes/ui/RESULTS.md, built in here:
///  - the child leads its OWN PROCESS GROUP, so cancel/timeout/output-cap can `kill(-pgid)` the whole tree;
///  - the child gets an explicit signal state (empty mask, default dispositions): without it the first
///    cancellation attempt silently failed;
///  - `POSIX_SPAWN_CLOEXEC_DEFAULT`: the child inherits only fds 0, 1 and 2, nothing else leaks into it;
///  - stdin is /dev/null; stdout and stderr are captured with caps.
public enum ProcessRunner {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pgid: pid_t = 0
        private var finished = false
        private(set) var timedOut = false
        private(set) var cancelled = false
        private(set) var truncated = false

        func setGroup(_ g: pid_t) { lock.lock(); pgid = g; lock.unlock() }
        func markFinished() { lock.lock(); finished = true; lock.unlock() }
        func markTruncated() { lock.lock(); truncated = true; lock.unlock() }

        func terminate(timedOut t: Bool = false, cancelled c: Bool = false) {
            lock.lock()
            if t { timedOut = true }
            if c { cancelled = true }
            let g = pgid
            let done = finished
            lock.unlock()
            guard g > 0, !done else { return }
            kill(-g, SIGTERM)
            // Escalate if the group ignores SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let fin = self.finished; self.lock.unlock()
                if !fin, kill(-g, 0) == 0 { kill(-g, SIGKILL) }
            }
        }
    }

    /// `onOutput` receives each chunk as it arrives (for live prompts such as an SSO device code). It is called
    /// from background threads, so it must be thread-safe and quick.
    public static func run(executable: String, arguments: [String], environment: [String: String],
                           timeout: TimeInterval, stdoutCap: Int, stderrCap: Int = 64 * 1024,
                           workingDirectory: String? = nil,
                           onOutput: (@Sendable (_ data: Data, _ isStdout: Bool) -> Void)? = nil) async throws -> ProcessOutcome {
        var outFds: [Int32] = [0, 0]
        var errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0 else { throw ProcessError.pipeFailed(errno: errno) }
        guard pipe(&errFds) == 0 else { close(outFds[0]); close(outFds[1]); throw ProcessError.pipeFailed(errno: errno) }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        if let cwd = workingDirectory { posix_spawn_file_actions_addchdir_np(&fileActions, cwd) }
        posix_spawn_file_actions_adddup2(&fileActions, outFds[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errFds[1], 2)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var noMask = sigset_t(); sigemptyset(&noMask)
        var allSigs = sigset_t(); sigfillset(&allSigs)
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setsigmask(&attr, &noMask)
        posix_spawnattr_setsigdefault(&attr, &allSigs)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)
        close(outFds[1]); close(errFds[1])
        guard rc == 0 else {
            close(outFds[0]); close(errFds[0])
            throw ProcessError.spawnFailed(errno: rc)
        }

        let state = State()
        state.setGroup(pid)
        let start = ProcessInfo.processInfo.systemUptime
        let spawned = pid

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessOutcome, Never>) in
                let group = DispatchGroup()
                let result = ResultBox()

                let timer = DispatchWorkItem { state.terminate(timedOut: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                func drain(_ fd: Int32, cap: Int, isStdout: Bool) {
                    group.enter()
                    DispatchQueue.global().async {
                        var data = Data()
                        var buf = [UInt8](repeating: 0, count: 65_536)
                        while true {
                            let n = read(fd, &buf, buf.count)
                            if n > 0 {
                                onOutput?(Data(bytes: buf, count: n), isStdout)
                                if data.count + n > cap {
                                    let room = max(0, cap - data.count)
                                    if room > 0 { data.append(buf, count: room) }
                                    if isStdout { state.markTruncated(); state.terminate() }
                                    // keep draining so the child is not blocked on a full pipe
                                } else {
                                    data.append(buf, count: n)
                                }
                            } else if n == 0 {
                                break
                            } else if errno == EINTR {
                                continue
                            } else {
                                break
                            }
                        }
                        close(fd)
                        result.set(isStdout ? \.stdout : \.stderr, data)
                        group.leave()
                    }
                }
                drain(outFds[0], cap: stdoutCap, isStdout: true)
                drain(errFds[0], cap: stderrCap, isStdout: false)

                group.enter()
                DispatchQueue.global().async {
                    var status: Int32 = 0
                    while waitpid(spawned, &status, 0) == -1 && errno == EINTR {}
                    result.status = status
                    group.leave()
                }

                group.notify(queue: .global()) {
                    timer.cancel()
                    state.markFinished()
                    let sig = result.status & 0x7f
                    let signaled = sig != 0 && sig != 0x7f
                    cont.resume(returning: ProcessOutcome(
                        status: signaled ? sig : ((result.status >> 8) & 0xff), signaled: signaled,
                        stdout: result.stdout, stderr: result.stderr, stdoutTruncated: state.truncated,
                        timedOut: state.timedOut, cancelled: state.cancelled, pid: spawned,
                        durationMs: (ProcessInfo.processInfo.systemUptime - start) * 1000))
                }
            }
        } onCancel: {
            state.terminate(cancelled: true)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()
        private var _status: Int32 = 0
        var stdout: Data { lock.lock(); defer { lock.unlock() }; return _stdout }
        var stderr: Data { lock.lock(); defer { lock.unlock() }; return _stderr }
        var status: Int32 {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); _status = newValue; lock.unlock() }
        }
        func set(_ key: KeyPath<ResultBox, Data>, _ data: Data) {
            lock.lock()
            if key == \ResultBox.stdout { _stdout = data } else { _stderr = data }
            lock.unlock()
        }
    }
}
