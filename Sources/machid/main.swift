import MacHIDDomain

// M0 placeholder. `list` and `info` arrive with the HID transport in M1.
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--version") {
    print("machid core-api \(coreAPIVersion)")
} else {
    print("usage: machid --version")
}
