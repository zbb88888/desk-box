import SwiftUI
import AppKit
import Virtualization

/// M14b：guest display 窗（virtio-gpu → NSView 展示）。
/// Host side display window是移动 AppKit 体确定，不在 daemon 进程;此窗归 GUI 中的 App-process VM。
struct DisplayWindow: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
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

    func start(kernelPath: URL, initrdPath: URL?, rootDiskPath: URL, cpu: Int = 2, memMiB: Int = 2048) {
        // 会话私盘：rootfs base 不可写（strategies 一致）。
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
            machine.stop { _ in DispatchQueue.main.async { self.status = "stopped"; self.machine = nil } }
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
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBox/display-console.log")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path.path, contents: nil)
        return try FileHandle(forWritingTo: path)
    }
}
