import Foundation
@preconcurrency import Virtualization
import DeskBoxCore

/// VZ delegate 只报告平台事件，不直接把平台状态提升为产品 Running。
final class VZRuntimeDelegate: NSObject, VZVirtualMachineDelegate {
    let onGuestStopped: @Sendable (NSError?) -> Void
    let onState: @Sendable (VZVirtualMachine.State) -> Void

    init(
        onGuestStopped: @escaping @Sendable (NSError?) -> Void,
        onState: @escaping @Sendable (VZVirtualMachine.State) -> Void = { _ in }
    ) {
        self.onGuestStopped = onGuestStopped
        self.onState = onState
        super.init()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onState(virtualMachine.state)
        onGuestStopped(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onState(virtualMachine.state)
        onGuestStopped(error as NSError)
    }
}
