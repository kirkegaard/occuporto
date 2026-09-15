//
//  PortScanner.swift
//  occuporto
//
//  Enumerates listening TCP/UDP sockets owned by the current user using
//  the low-level libproc APIs (no shelling out to lsof / netstat).
//

import Foundation

struct PortEntry: Identifiable, Hashable {
    let id: String
    let pid: pid_t
    let processName: String
    let port: UInt16
    let proto: String // "tcp" or "udp"
    let executablePath: String?
    let workingDirectory: String?

    /// Last two path components of the working directory, e.g.
    /// "/Users/christian/Development/omnigame/sites" -> "omnigame/sites"
    var truncatedPath: String? {
        guard let workingDirectory else { return nil }
        let components = (workingDirectory as NSString).pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return workingDirectory }
        let lastTwo = components.suffix(2)
        return lastTwo.joined(separator: "/")
    }

    /// True for processes that live inside a `.app` bundle under
    /// `/Applications` or `/System/Applications` (e.g. Chrome, Spotify,
    /// Discord). These are typically less interesting than ad-hoc dev
    /// processes (node, python, custom binaries, etc.) and are grouped
    /// separately in the UI.
    var isKnownApp: Bool {
        guard let executablePath else { return false }
        return executablePath.hasPrefix("/Applications/")
            || executablePath.hasPrefix("/System/Applications/")
    }

    /// True for macOS system daemons/services (e.g. ControlCenter,
    /// reportd, replicatord, sharingd) that live under `/System`,
    /// `/usr/libexec`, `/usr/sbin`, or `/usr/bin`. Not user apps or dev
    /// processes, so grouped separately as "System".
    var isSystemProcess: Bool {
        guard let executablePath else { return false }
        guard !isKnownApp else { return false }
        return executablePath.hasPrefix("/System/")
            || executablePath.hasPrefix("/usr/libexec/")
            || executablePath.hasPrefix("/usr/sbin/")
            || executablePath.hasPrefix("/usr/bin/")
    }
}

enum PortScanner {

    /// Scans for all TCP (LISTEN) and UDP (bound) sockets owned by the
    /// current user and returns one entry per (pid, port) pair.
    static func scan() -> [PortEntry] {
        let currentUID = getuid()
        var results: [PortEntry] = []

        for pid in allPIDs() {
            guard let uid = uid(forPID: pid), uid == currentUID else { continue }
            guard pid > 0 else { continue }

            let fds = fileDescriptors(forPID: pid)
            guard !fds.isEmpty else { continue }

            var portsForPID: Set<PortEntry> = []

            for fd in fds where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                guard let socketInfo = socketInfo(forPID: pid, fd: fd.proc_fd) else { continue }

                switch Int32(socketInfo.psi.soi_kind) {
                case Int32(SOCKINFO_TCP):
                    let tcp = socketInfo.psi.soi_proto.pri_tcp
                    guard tcp.tcpsi_state == TCPS_LISTEN else { continue }
                    let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                    guard lport > 0 else { continue }
                    portsForPID.insert(makeEntry(pid: pid, port: lport, proto: "tcp"))

                case Int32(SOCKINFO_IN):
                    // Bound UDP sockets (no explicit LISTEN state for UDP).
                    guard socketInfo.psi.soi_protocol == IPPROTO_UDP else { continue }
                    let inInfo = socketInfo.psi.soi_proto.pri_in
                    let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: inInfo.insi_lport))
                    guard lport > 0 else { continue }
                    portsForPID.insert(makeEntry(pid: pid, port: lport, proto: "udp"))

                default:
                    continue
                }
            }

            results.append(contentsOf: portsForPID)
        }

        return results.sorted { $0.port == $1.port ? $0.processName < $1.processName : $0.port < $1.port }
    }

    // MARK: - Entry construction

    private static func makeEntry(pid: pid_t, port: UInt16, proto: String) -> PortEntry {
        PortEntry(
            id: "\(pid)-\(proto)-\(port)",
            pid: pid,
            processName: processName(forPID: pid),
            port: port,
            proto: proto,
            executablePath: executablePath(forPID: pid),
            workingDirectory: workingDirectory(forPID: pid)
        )
    }

    // MARK: - libproc helpers

    private static func allPIDs() -> [pid_t] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return [] }

        let actualCount = min(Int(actualSize) / MemoryLayout<pid_t>.size, pids.count)
        return Array(pids.prefix(actualCount)).filter { $0 > 0 }
    }

    private static func uid(forPID pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return info.pbi_uid
    }

    private static func processName(forPID pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }

    private static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func workingDirectory(forPID pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }

        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { rawBuffer -> String? in
            let ptr = rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            let path = String(cString: ptr)
            return path.isEmpty ? nil : path
        }
    }

    private static func fileDescriptors(forPID pid: pid_t) -> [proc_fdinfo] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard actualSize > 0 else { return [] }

        let actualCount = min(Int(actualSize) / MemoryLayout<proc_fdinfo>.size, fds.count)
        return Array(fds.prefix(actualCount))
    }

    private static func socketInfo(forPID pid: pid_t, fd: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let result = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        guard result == size else { return nil }
        return info
    }

    // MARK: - Kill

    /// Sends SIGTERM to the given process.
    @discardableResult
    static func terminate(pid: pid_t) -> Bool {
        kill(pid, SIGTERM) == 0
    }
}
