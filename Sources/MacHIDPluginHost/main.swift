import Foundation
import JavaScriptCore

// MacHIDPluginHost: runs one plugin script in JavaScriptCore. It is started by the app under `sandbox-exec` with a
// deny-default profile and talks to the app only through stdin/stdout, one JSON object per line. The script gets no
// file, network, process, timer or module access: only `hid.*`, `log` and `sleep`, and every hid call is a round trip
// to the app, which enforces the permissions the user approved. It exits when stdin closes.
//
// App to host:  {"op":"load","source":"...","limits":{...}}  {"op":"describe"}  {"op":"read","capability":"x"}
//               {"op":"write","capability":"x","json":"<json text>"}
//               replies to hid calls: {"ok":true,...} / {"ok":false,"error":"..."}
// Host to app:  {"type":"loaded","describe":bool}  {"type":"hid","call":"...",...}  {"type":"log","message":"..."}
//               {"type":"result","json":"<json text>"}  {"type":"error","message":"..."}

struct Limits {
    var maxCalls = 64
    var maxBytesPerCall = 256
    var maxSeconds = 4.0
    var maxLogLines = 20
    var maxLogChars = 200
    var maxSleepMs = 200
    var maxInputTimeoutMs = 2000
}

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func writeLine(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { exit(3) }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func readObject() -> [String: Any]? {
    guard let line = readLine(strippingNewline: true) else { return nil }   // stdin closed: the app is gone
    guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { exit(4) }
    return object
}

final class Host: @unchecked Sendable {
    var limits = Limits()
    let context = JSContext()!
    var calls = 0
    var logLines = 0
    var started = Date()
    var failure: String?

    init() {
        context.exceptionHandler = { [unowned self] _, exception in
            self.failure = exception?.toString() ?? "script error"
        }
        // Nothing the script does may reach outside the context; drop the few globals that could matter.
        context.evaluateScript("delete globalThis.WebAssembly;")
    }

    func checkBudget() throws {
        if Date().timeIntervalSince(started) > limits.maxSeconds { throw HostError("time limit exceeded") }
    }

    func bytes(_ value: JSValue?, name: String) throws -> [Int] {
        guard let value, value.isArray, let array = value.toArray() else { throw HostError("\(name) must be an array of bytes") }
        guard array.count <= limits.maxBytesPerCall else { throw HostError("too many bytes in one call") }
        var out: [Int] = []
        for item in array {
            guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == number.doubleValue.rounded(), (0...255).contains(number.intValue) else { throw HostError("bytes must be integers 0-255") }
            out.append(number.intValue)
        }
        return out
    }

    func integer(_ value: JSValue?, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value, value.isNumber else { throw HostError("\(name) must be a number") }
        let d = value.toDouble()
        guard d == d.rounded(), d >= Double(range.lowerBound), d <= Double(range.upperBound) else { throw HostError("\(name) out of range") }
        return Int(d)
    }

    /// One synchronous round trip to the app.
    func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        try checkBudget()
        calls += 1
        guard calls <= limits.maxCalls else { throw HostError("too many device calls") }
        writeLine(request)
        guard let reply = readObject() else { exit(0) }
        guard reply["ok"] as? Bool == true else { throw HostError(reply["error"] as? String ?? "denied") }
        return reply
    }

    func args() -> [JSValue] { JSContext.currentArguments() as? [JSValue] ?? [] }

    func throwing(_ error: Error) -> Any? {
        context.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
        return nil
    }

    func install() {
        let hid = JSValue(newObjectIn: context)!
        func define(_ name: String, _ body: @escaping @convention(block) () -> Any?) {
            hid.setValue(unsafeBitCast(body, to: AnyObject.self), forProperty: name)
        }
        define("sendFeature") { [unowned self] in
            do {
                let a = args()
                let id = try integer(a.first, "reportID", 0...255)
                let data = try bytes(a.count > 1 ? a[1] : nil, name: "bytes")
                _ = try roundTrip(["type": "hid", "call": "sendFeature", "reportID": id, "bytes": data])
                return nil
            } catch { return throwing(error) }
        }
        define("sendOutput") { [unowned self] in
            do {
                let a = args()
                let id = try integer(a.first, "reportID", 0...255)
                let data = try bytes(a.count > 1 ? a[1] : nil, name: "bytes")
                _ = try roundTrip(["type": "hid", "call": "sendOutput", "reportID": id, "bytes": data])
                return nil
            } catch { return throwing(error) }
        }
        define("getFeature") { [unowned self] in
            do {
                let a = args()
                let id = try integer(a.first, "reportID", 0...255)
                let length = try integer(a.count > 1 ? a[1] : nil, "length", 1...limits.maxBytesPerCall)
                let reply = try roundTrip(["type": "hid", "call": "getFeature", "reportID": id, "length": length])
                return Array((reply["bytes"] as? [Int] ?? []).prefix(limits.maxBytesPerCall))
            } catch { return throwing(error) }
        }
        define("nextInput") { [unowned self] in
            do {
                let timeout = try integer(args().first, "timeoutMs", 0...limits.maxInputTimeoutMs)
                let reply = try roundTrip(["type": "hid", "call": "nextInput", "timeoutMs": timeout])
                if reply["timeout"] as? Bool == true { return NSNull() }
                return ["reportID": reply["reportID"] as? Int ?? 0, "bytes": Array((reply["bytes"] as? [Int] ?? []).prefix(limits.maxBytesPerCall))]
            } catch { return throwing(error) }
        }
        context.setObject(hid, forKeyedSubscript: "hid" as NSString)
        context.evaluateScript("Object.freeze(hid);")

        let log: @convention(block) () -> Void = { [unowned self] in
            guard logLines < limits.maxLogLines else { return }
            logLines += 1
            let text = args().first?.toString() ?? ""
            writeLine(["type": "log", "message": String(text.prefix(limits.maxLogChars))])
        }
        context.setObject(log, forKeyedSubscript: "log" as NSString)
        let sleep: @convention(block) () -> Void = { [unowned self] in
            guard let ms = args().first, ms.isNumber, ms.toDouble().isFinite, (try? checkBudget()) != nil else { return }
            usleep(UInt32(max(0, min(Int(ms.toDouble()), limits.maxSleepMs))) * 1000)
        }
        context.setObject(sleep, forKeyedSubscript: "sleep" as NSString)
    }

    func isFunction(_ name: String) -> Bool {
        context.evaluateScript("typeof \(name) === 'function'")?.toBool() ?? false
    }

    /// Calls a script function and reports its JSON result (or the error) to the app.
    func run(_ function: String, _ arguments: [Any]) {
        started = Date(); calls = 0; logLines = 0; failure = nil
        guard let fn = context.objectForKeyedSubscript(function), fn.isObject else { writeLine(["type": "error", "message": "no \(function)()"]); return }
        let result = fn.call(withArguments: arguments)
        if let failure { writeLine(["type": "error", "message": failure]); return }
        guard let result, !result.isUndefined else { writeLine(["type": "result", "json": "null"]); return }
        let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [result])
        if let json, json.isString, let text = json.toString(), text.utf8.count <= 4096 { writeLine(["type": "result", "json": text]) }
        else { writeLine(["type": "error", "message": "the script returned a value that is not JSON or is too large"]) }
    }
}

let host = Host()
host.install()

while let message = readObject() {
    switch message["op"] as? String {
    case "load":
        guard let source = message["source"] as? String, source.utf8.count <= 128 * 1024 else { writeLine(["type": "error", "message": "bad script"]); continue }
        if let limits = message["limits"] as? [String: Any] {
            if let v = limits["maxCalls"] as? Int { host.limits.maxCalls = min(max(v, 1), 256) }
            if let v = limits["maxSeconds"] as? Double { host.limits.maxSeconds = min(max(v, 0.1), 10) }
        }
        host.failure = nil
        host.started = Date()
        host.context.evaluateScript(source)
        if let failure = host.failure { writeLine(["type": "error", "message": failure]); continue }
        writeLine(["type": "loaded", "describe": host.isFunction("describe")])
    case "describe":
        host.run("describe", [])
    case "read":
        guard let capability = message["capability"] as? String else { writeLine(["type": "error", "message": "bad request"]); continue }
        host.run("read", [capability])
    case "write":
        guard let capability = message["capability"] as? String, let json = message["json"] as? String else {
            writeLine(["type": "error", "message": "bad request"]); continue
        }
        host.failure = nil
        let value = host.context.objectForKeyedSubscript("JSON")?.invokeMethod("parse", withArguments: [json])
        if host.failure != nil { writeLine(["type": "error", "message": "bad value"]); continue }
        host.run("write", [capability, value as Any])
    default:
        writeLine(["type": "error", "message": "unknown op"])
    }
}
