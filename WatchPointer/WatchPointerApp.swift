import CoreBluetooth
import CoreMotion
import SwiftUI
import WatchKit

// Must match the Mac receiver.
let serviceUUID = CBUUID(string: "6B1E0001-9F4C-4C2A-9B8E-3D2A1C0F5E01")
let inputUUID = CBUUID(string: "6B1E0002-9F4C-4C2A-9B8E-3D2A1C0F5E01")
/// Subscribing to this tells the Mac the moment the watch connects or disconnects. (It sends nothing back.)
let outputUUID = CBUUID(string: "6B1E0003-9F4C-4C2A-9B8E-3D2A1C0F5E01")

@main
struct WatchPointerApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

/// Packets: [kind, Int16 LE a, Int16 LE b].
/// `.aim`: where the watch's 12 o'clock edge points, relative to "Center", in hundredths of a degree
/// (a = turned left, b = tipped up), then UInt16 LE: when it was measured, in ms on the watch's clock (wraps).
/// The Mac smooths with those times; Bluetooth delivers samples in bursts, so arrival times are useless.
/// `.pause`: a = 1 paused, 0 resumed.
/// `.info`: [kind, JSON] with the watch's model id, watchOS, battery and name (not the fixed 5 bytes).
/// `.drag`: a = 1 grab (mouse down), 0 drop (mouse up).
/// `.move`: a = dx, b = dy — the finger moved the pad by this many Mac pixels (trackpad mode).
/// Clicks and drags may add the same UInt16 ms time as `.aim`: when the thumb touched down (or lifted, for a drop).
enum Kind: UInt8 { case aim = 0, leftClick = 1, rightClick = 2, scroll = 3, center = 4, pause = 5, info = 6, drag = 7, move = 8, scrollMode = 9, keepAlive = 10, smoothDelay = 11 }

/// Press again and keep the finger perfectly still this long before it grabs (drag). Moving cancels it.
let holdToDrag = 1.0

/// A Mac running the receiver, seen nearby.
struct FoundMac: Identifiable {
    let id: UUID
    let name: String
    let peripheral: CBPeripheral
}

final class Pointer: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var connected = false
    @Published var paused = false
    /// Macs nearby you can pair with (only while nothing is paired).
    @Published var found: [FoundMac] = []
    /// The Mac you paired with. The watch only ever connects to this one until you forget it.
    @Published var pairedName = UserDefaults.standard.string(forKey: "pairedMacName")
    private var pairedID = UserDefaults.standard.string(forKey: "pairedMacID").flatMap(UUID.init)

    private var central: CBCentralManager!
    private var mac: CBPeripheral?
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private let motion = CMMotionManager()

    private var heading = 0.0       // radians turned left since "Center"
    private var elevation = 0.0     // radians the top edge points above horizontal, right now
    private var elevationZero = 0.0 // elevation when "Center" was pressed
    private var lastTimestamp: TimeInterval?
    private var infoTimer: Timer?
    private var keepAliveTimer: Timer?
    /// 0 = trackpad-like smooth scrolling, 1 = hard stop. Picked in the menu, resent on every connect.
    private var scrollModeValue: Int16 = 0
    private var scrollTarget = 0.0   // pixels the Crown has asked for, in total
    private var scrollSent = 0.0     // pixels already handed to the Mac
    private var scrollTimer: Timer?
    private var moveTimer: Timer?
    private var movePendingX = 0.0   // cursor pixels waiting for the next send slot
    private var movePendingY = 0.0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        // Trackpad build: the cursor follows the finger, not the wrist, so the gyro stream stays off.
        // One 120 Hz pump sends the cursor and the Crown backlog, so the rate stays steady even when the
        // touch samples arrive unevenly, and nothing queues up faster than the link can take it.
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            self?.flushScroll()
        }
        // Fixed 60 Hz cursor clock: one packet every 16.7 ms, even when the finger is still, so the Mac always
        // sees a steady sample rate and the link never looks idle.
        moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.flushMove(always: true)
        }
    }

    deinit {
        scrollTimer?.invalidate()
        moveTimer?.invalidate()
    }

    /// Trackpad: the finger's travel is only accumulated here. The 120 Hz pump sends it, merging whatever
    /// arrived since the last slot into one packet — steady rate, and never more than the link can carry.
    func move(_ dx: Int16, _ dy: Int16) {
        movePendingX += Double(dx)
        movePendingY += Double(dy)
    }

    private func flushMove(always: Bool = false) {
        guard let mac, let input, mac.canSendWriteWithoutResponse else { return }
        let dx = Int16(clamping: Int(movePendingX.rounded(.towardZero)))
        let dy = Int16(clamping: Int(movePendingY.rounded(.towardZero)))
        guard dx != 0 || dy != 0 || always else { return }
        movePendingX -= Double(dx)
        movePendingY -= Double(dy)
        let bytes = [Kind.move.rawValue,
                     UInt8(truncatingIfNeeded: dx), UInt8(truncatingIfNeeded: dx >> 8),
                     UInt8(truncatingIfNeeded: dy), UInt8(truncatingIfNeeded: dy >> 8)]
        mac.writeValue(Data(bytes), for: input, type: .withoutResponse)
    }

    /// The menu's scrolling style: 0 = smooth (trackpad-like), 1 = hard stop. Remembers across connects.
    func setScrollMode(_ mode: Int16) {
        scrollModeValue = mode
        send(.scrollMode, mode)
    }

    /// Cursor smoothing time constant, in milliseconds; 0 turns the jitter buffer off entirely.
    func setSmoothDelay(_ ms: Int16) {
        send(.smoothDelay, ms)
    }

    /// Whatever direction the watch points now becomes the middle of the screen.
    func center() {
        recenter()
        send(.center)
    }

    /// Paused: the cursor stays put (aim keeps tracking, so resuming lines up again).
    func togglePause() {
        paused.toggle()
        send(.pause, paused ? 1 : 0)
    }

    private func recenter() {
        heading = 0
        elevationZero = elevation
    }

    /// Tells the Mac which watch this is. Sent on connect, then every minute for the battery level.
    private func sendInfo() {
        guard let mac, let input else { return }
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let info: [String: Any] = [
            "model": model,                                          // e.g. "Watch7,5"
            "os": device.systemVersion,
            "battery": device.batteryLevel < 0 ? -1 : Int((device.batteryLevel * 100).rounded()),
            "charging": device.batteryState == .charging || device.batteryState == .full,
            "name": String(device.name.prefix(40)),                  // kept short so it fits in one packet
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: info) else { return }
        mac.writeValue(Data([Kind.info.rawValue]) + json, for: input, type: .withResponse)
    }

    // MARK: Motion → aim

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100

        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let dt = lastTimestamp.map { min(data.timestamp - $0, 0.05) } ?? 0
            lastTimestamp = data.timestamp

            let g = data.gravity, r = data.rotationRate
            let n = max((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 1e-6)
            let up = (x: -g.x / n, y: -g.y / n, z: -g.z / n)
            // Up/down comes straight from gravity, so it never drifts.
            elevation = asin(min(max(up.y, -1), 1))
            // Left/right has no absolute reference, so add up every turn around the vertical axis.
            // No dead zone: dropping slow turns is what made the old version slide out of line.
            heading += (r.x * up.x + r.y * up.y + r.z * up.z) * dt

            guard connected else { return }
            flushScroll()
            guard !paused else { return }
            sendAim(at: data.timestamp)
        }
    }

    private func sendAim(at timestamp: TimeInterval) {
        guard let mac, let input, mac.canSendWriteWithoutResponse else { return } // link busy: the next sample replaces this one
        let left = Int16(clamping: Int((remainder(heading, 2 * .pi) * 180 / .pi * 100).rounded()))
        let upward = Int16(clamping: Int(((elevation - elevationZero) * 180 / .pi * 100).rounded()))
        let ms = UInt16(truncatingIfNeeded: Int64(timestamp * 1000))
        let bytes = [Kind.aim.rawValue,
                     UInt8(truncatingIfNeeded: left), UInt8(truncatingIfNeeded: left >> 8),
                     UInt8(truncatingIfNeeded: upward), UInt8(truncatingIfNeeded: upward >> 8),
                     UInt8(truncatingIfNeeded: ms), UInt8(truncatingIfNeeded: ms >> 8)]
        mac.writeValue(Data(bytes), for: input, type: .withoutResponse)
    }

    /// `at`: when it happened on the watch's clock (same clock as the motion samples). Clicks and drags send the
    /// moment the thumb touched down, so the Mac clicks where you were pointing then, before the tap jolted the watch.
    /// Each Crown event is a tiny fraction, so the total is kept and bled out over the next frames (see `flushScroll`).
    func scroll(by pixels: Double) {
        scrollTarget += pixels
    }

    /// Crown scrolling: every turn adds to a target, and the 60 Hz timer hands the whole backlog over each frame.
    /// The smooth part happens on the Mac (a 120 Hz interpolator), so the watch doesn't add lag of its own.
    private func flushScroll() {
        guard let mac, let input, mac.canSendWriteWithoutResponse else { return }
        let remaining = scrollTarget - scrollSent
        let whole = Int16(clamping: Int(remaining.rounded(.towardZero)))
        guard whole != 0 else { return }
        scrollSent += Double(whole)
        let bytes = [Kind.scroll.rawValue, UInt8(truncatingIfNeeded: whole), UInt8(truncatingIfNeeded: whole >> 8), 0, 0]
        mac.writeValue(Data(bytes), for: input, type: .withoutResponse)
    }

    func send(_ kind: Kind, _ a: Int16 = 0, _ b: Int16 = 0, at time: TimeInterval? = nil) {
        guard let mac, let input else { return }
        var bytes = [kind.rawValue,
                     UInt8(truncatingIfNeeded: a), UInt8(truncatingIfNeeded: a >> 8),
                     UInt8(truncatingIfNeeded: b), UInt8(truncatingIfNeeded: b >> 8)]
        if let time {
            let ms = UInt16(truncatingIfNeeded: Int64(time * 1000))
            bytes += [UInt8(truncatingIfNeeded: ms), UInt8(truncatingIfNeeded: ms >> 8)]
        }
        // Clicks must not be dropped; aim samples can be.
        mac.writeValue(Data(bytes), for: input, type: kind == .aim ? .withoutResponse : .withResponse)
    }

    // MARK: Bluetooth

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { start() }
    }

    /// Paired: wait for that Mac (the connect completes whenever it's in range). Not paired: list what's nearby.
    private func start() {
        guard central.state == .poweredOn, mac == nil else { return }
        found = []
        if let pairedID, let known = central.retrievePeripherals(withIdentifiers: [pairedID]).first {
            connect(to: known)
        }
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        if let pairedID {
            if peripheral.identifier == pairedID { connect(to: peripheral) }
            return
        }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Mac"
        guard !found.contains(where: { $0.id == peripheral.identifier }) else { return }
        found.append(FoundMac(id: peripheral.identifier, name: name, peripheral: peripheral))
    }

    /// Pair with this Mac: remember it, then connect.
    func pair(_ found: FoundMac) {
        pairedID = found.id
        pairedName = found.name
        UserDefaults.standard.set(found.id.uuidString, forKey: "pairedMacID")
        UserDefaults.standard.set(found.name, forKey: "pairedMacName")
        self.found = []
        connect(to: found.peripheral)
    }

    /// Unpair, drop the connection and go back to listing nearby Macs.
    func forget() {
        pairedID = nil
        pairedName = nil
        UserDefaults.standard.removeObject(forKey: "pairedMacID")
        UserDefaults.standard.removeObject(forKey: "pairedMacName")
        if let mac { central.cancelPeripheralConnection(mac) }
        reset()
    }

    private func connect(to peripheral: CBPeripheral) {
        guard mac == nil else { return }
        central.stopScan()
        mac = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reset()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([inputUUID, outputUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        input = service.characteristics?.first { $0.uuid == inputUUID }
        output = service.characteristics?.first { $0.uuid == outputUUID }
        if let output { peripheral.setNotifyValue(true, for: output) }
        connected = input != nil
        recenter()
        sendInfo()
        send(.scrollMode, scrollModeValue)
        infoTimer?.invalidate()
        keepAliveTimer?.invalidate()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sendInfo() }
        // A quiet tick every half second, so the Mac knows the link is fine even while the finger is lifted
        // (the trackpad sends nothing when nobody touches it).
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.send(.keepAlive)
        }
    }

    private func reset() {
        mac = nil
        input = nil
        output = nil
        connected = false
        paused = false
        scrollTarget = 0
        scrollSent = 0
        movePendingX = 0
        movePendingY = 0
        infoTimer?.invalidate()
        keepAliveTimer?.invalidate()
        start()
    }
}
