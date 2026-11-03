// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT
//
// Development-only boot test for the ThruRNDIS-Wi-Fi guest: same device layout as
// ThruRNDIS (generic platform, VZNAT, XHCI, virtio console on hvc0) but
// without USB passthrough, which needs ThruRNDIS's restricted entitlement.
//   vmrun <Image> <initramfs> <console-log> <seconds> [kernel args...]

import Foundation
import Virtualization

let arguments = CommandLine.arguments
guard arguments.count >= 5, let seconds = Double(arguments[4]) else {
    FileHandle.standardError.write("usage: vmrun <Image> <initramfs> <console-log> <seconds> [kernel args...]\n".data(using: .utf8)!)
    exit(2)
}

let logURL = URL(fileURLWithPath: arguments[3])
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try FileHandle(forWritingTo: logURL)
let consoleInput = Pipe()

let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: arguments[1]))
bootLoader.initialRamdiskURL = URL(fileURLWithPath: arguments[2])
bootLoader.commandLine = (["console=hvc0", "rdinit=/sbin/init", "modules=virtio_pci,virtio_mmio,virtio_console"]
    + arguments.dropFirst(5)).joined(separator: " ")

let console = VZVirtioConsoleDeviceSerialPortConfiguration()
console.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: consoleInput.fileHandleForReading,
    fileHandleForWriting: logHandle
)

let network = VZVirtioNetworkDeviceConfiguration()
network.attachment = VZNATNetworkDeviceAttachment()
network.macAddress = VZMACAddress(string: "02:00:5E:10:00:99")!

let configuration = VZVirtualMachineConfiguration()
configuration.platform = VZGenericPlatformConfiguration()
configuration.cpuCount = 1
configuration.memorySize = 1024 * 1024 * 1024
configuration.bootLoader = bootLoader
configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
configuration.serialPorts = [console]
configuration.usbControllers = [VZXHCIControllerConfiguration()]
configuration.networkDevices = [network]
try configuration.validate()

let machine = VZVirtualMachine(configuration: configuration)
machine.start { result in
    if case .failure(let error) = result {
        FileHandle.standardError.write("start failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    print("VM started; console -> \(logURL.path)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    machine.stop { _ in exit(0) }
}
dispatchMain()
