import Foundation

public struct TemperatureReading: Sendable, Equatable {
    public var chip: Double?
    public var battery: Double?
    public var storage: Double?

    public init(chip: Double? = nil, battery: Double? = nil, storage: Double? = nil) {
        self.chip = chip
        self.battery = battery
        self.storage = storage
    }

    public var isEmpty: Bool { chip == nil && battery == nil && storage == nil }

    public static func summarize(_ sensors: [(String, Double)]) -> TemperatureReading {
        let valid = sensors.filter { $0.1 > 0 && $0.1 < 130 }
        func average(_ match: (String) -> Bool) -> Double? {
            let values = valid.filter { match($0.0.lowercased()) }.map(\.1)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        func peak(_ match: (String) -> Bool) -> Double? {
            valid.filter { match($0.0.lowercased()) }.map(\.1).max()
        }
        let chip = peak { $0.contains("tdie") }
            ?? peak { $0.contains("cpu") || $0.contains("soc") }
            ?? peak { $0.contains("tdev") }
        return TemperatureReading(
            chip: chip,
            battery: average { $0.contains("battery") },
            storage: average { $0.contains("nand") || $0.contains("ssd") }
        )
    }
}

public final class TemperatureSensors: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn = @convention(c) (AnyObject, Int32) -> Double

    private let lock = NSLock()
    private var client: AnyObject?
    private var copyServices: CopyServicesFn?
    private var copyProperty: CopyPropertyFn?
    private var copyEvent: CopyEventFn?
    private var floatValue: FloatValueFn?

    public init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let services = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let property = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let event = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let value = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return }
        let createFn = unsafeBitCast(create, to: CreateFn.self)
        guard let client = createFn(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        copyServices = unsafeBitCast(services, to: CopyServicesFn.self)
        copyProperty = unsafeBitCast(property, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(event, to: CopyEventFn.self)
        floatValue = unsafeBitCast(value, to: FloatValueFn.self)
    }

    public func sensors() -> [(String, Double)] {
        lock.lock()
        defer { lock.unlock() }
        guard let client, let copyServices, let copyProperty, let copyEvent, let floatValue,
              let list = copyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return [] }
        var result: [(String, Double)] = []
        for service in list {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue()
            else { continue }
            result.append((name, floatValue(event, 15 << 16)))
        }
        return result
    }

    public func read() -> TemperatureReading {
        TemperatureReading.summarize(sensors())
    }
}
