import SwiftUI
import AppKit
import Virtualization
import DeskBoxVZ

/// M14b：guest display 窗（virtio-gpu → NSView 展示）。
/// Host side display window是移动 AppKit 体确定，不在 daemon 进程;此窗归 GUI 中的 App-process VM。
struct DisplayWindow: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        // Cmd+Q bug fix：capturesSystemKeys=true 会把 ⌘Q/⌘Tab 等系统快捷键转发进 guest，
        // 导致 Display 窗口聚焦时无法退出 App。fbcon guest 不需要系统热键。
        view.capturesSystemKeys = false
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = machine
    }
}

/// GUI-in-process VM viewmodel（display sandbox 专属，daemon 的 sandbox 不相干）。
private final class VMBox: @unchecked Sendable {
    let machine: VZVirtualMachine
    init(machine: VZVirtualMachine) { self.machine = machine }
}

final class DisplaySandboxViewModel: ObservableObject, @unchecked Sendable {
    @Published var busy = false
    @Published var status: String = "未启动"
    @Published var machine: VZVirtualMachine?
    private var runtimeSandboxId: String? = nil
    private let animQueue = DispatchQueue(label: "deskbox.gui.displayvm")
    private var consolePipe: (fh: FileHandle?, cleanup: (() -> Void)?) = (nil, nil)
    /// 会话私盘（rootfs 临时副本）：stop/退出时必须删，否则每次 Open Display 泄漏一份 512MiB。
    private var sessionDisk: URL? = nil
    private var terminateObserver: NSObjectProtocol? = nil

    init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.cleanupSessionDisk() }
    }

    deinit {
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        cleanupSessionDisk()
    }

    private func cleanupSessionDisk() {
        if let disk = sessionDisk {
            try? FileManager.default.removeItem(at: disk)
            sessionDisk = nil
        }
    }

    func start(kernelPath: URL, initrdPath: URL?, rootDiskPath: URL, cpu: Int = 2, memMiB: Int = 2048) {
        // 会话私盘：rootfs base 不可写（strategies 一致）。
        cleanupSessionDisk()
        let sessionDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-display-root-\(UUID().uuidString).raw")
        do {
            try FileManager.default.copyItem(at: rootDiskPath, to: sessionDisk)
        } catch {
            DispatchQueue.main.async {
                self.busy = false
                self.status = "copy rootfs fail: \(error.localizedDescription)"
            }
            return
        }
        let activeRootDisk = sessionDisk
        self.sessionDisk = sessionDisk
        DispatchQueue.main.async { self.busy = true; self.status = "starting" }
        animQueue.async {
            do {
                let machine = try self.makeMachine(kernel: kernelPath, initrd: initrdPath, rootDisk: activeRootDisk, cpu: cpu, memMiB: memMiB)
                let vmBox = VMBox(machine: machine)
                DispatchQueue.main.async { self.machine = machine }
                vmBox.machine.start { result in
                    DispatchQueue.main.async {
                        self.busy = false
                        switch result {
                        case .success: self.status = "running"
                        case .failure(let e): self.status = "boot error: \(e.localizedDescription)"
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = "config error: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        guard let machine else { return }
        if machine.canStop {
            machine.stop { _ in DispatchQueue.main.async {
                self.status = "stopped"
                self.machine = nil
                self.cleanupSessionDisk()
            } }
        } else if machine.canPause {
            machine.pause { _ in }
        }
    }

    private func makeMachine(kernel: URL, initrd: URL?, rootDisk: URL, cpu: Int, memMiB: Int) throws -> VZVirtualMachine {
        let bootLoader = VZLinuxBootLoader(kernelURL: kernel)
        if let initrd { bootLoader.initialRamdiskURL = initrd }
        bootLoader.commandLine = "console=hvc0 console=tty0 loglevel=7 root=/dev/vda rw init=/init"

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = cpu
        configuration.memorySize = UInt64(memMiB) * 1024 * 1024
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let gfx = VZVirtioGraphicsDeviceConfiguration()
        gfx.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
        configuration.graphicsDevices = [gfx]

        // serial console（程序到 stdout 调试）
        let serial = VZVirtioConsoleDeviceConfiguration()
        let consolePort = VZVirtioConsolePortConfiguration()
        let serialAttacher = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: nil
        )
        consolePort.name = "org.linux.console"
        consolePort.isConsole = true
        consolePort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: try self.consoleFileHandle()
        )
        serial.ports[0] = consolePort
        configuration.consoleDevices = [serial]
        _ = serialAttacher

        let attachment = try VZDiskImageStorageDeviceAttachment(url: rootDisk, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        try configuration.validate()
        return VZVirtualMachine(configuration: configuration)
    }

    private func consoleFileHandle() throws -> FileHandle {
        let path = DeskBoxPaths.supportRoot.appendingPathComponent("display-console.log")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path.path, contents: nil)
        return try FileHandle(forWritingTo: path)
    }
}
