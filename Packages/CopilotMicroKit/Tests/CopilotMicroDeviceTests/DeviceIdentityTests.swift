import CopilotMicroDevice
import Testing

@Suite("Creator Micro 2 identity")
struct DeviceIdentityTests {
    @Test("Vendor, product, usage pair, and report sizes are all required")
    func fullIdentityIsRequired() {
        let descriptor = makeDescriptor()
        #expect(descriptor.qualification == .supportedCandidate)
        #expect(descriptor.transport == .usb)

        #expect(makeDescriptor(vendorID: 1).qualification == .unsupported)
        #expect(makeDescriptor(productID: 1).qualification == .unsupported)
        #expect(makeDescriptor(product: "Other device").qualification == .unsupported)
        #expect(makeDescriptor(transport: .unknown).qualification == .unsupported)
        #expect(makeDescriptor(usagePairs: []).qualification == .unsupported)
        #expect(makeDescriptor(inputBytes: 32).qualification == .unsupported)
        #expect(makeDescriptor(inputBytes: 4097).qualification == .unsupported)
    }

    private func makeDescriptor(
        vendorID: Int = 0x303A,
        productID: Int = 0x8298,
        product: String = "Creator Micro 2",
        transport: DeviceTransport = .usb,
        usagePairs: [HIDUsagePair] = [HIDUsagePair(page: 0xFF00, usage: 1)],
        inputBytes: Int = 64
    ) -> HIDDeviceDescriptor {
        HIDDeviceDescriptor(
            registryID: 42,
            vendorID: vendorID,
            productID: productID,
            product: product,
            transport: transport,
            primaryUsagePage: 1,
            primaryUsage: 6,
            usagePairs: usagePairs,
            maximumInputReportBytes: inputBytes,
            maximumOutputReportBytes: 64,
            serialPresent: true
        )
    }
}
