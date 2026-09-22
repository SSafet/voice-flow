import Foundation
import AppKit
import MCP

// Unrelated Captured compilation collaborators; no app/session is constructed.
func vflog(_ message: String) {}
final class PendingInteraction { var sessionId: String? }
struct CaptureSummary {}
final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 30
    var watcherDenseApps: Set<String> = []
}

private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var started = 0, completed = 0, failed = 0, effects = 0
    var current: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
    func start() { lock.withLock { started += 1 } }
    func finish(_ success: Bool) { lock.withLock { if success { completed += 1 } else { failed += 1 } } }
    func effect() { lock.withLock { effects += 1 } }
    func stats() -> [String: Any] {
        lock.withLock { ["active":active,"started":started,"completed":completed,"failed":failed,"effects":effects] }
    }
}
private actor EffectGate {
    var held = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    func hold() { held = true }
    func enter() async {
        if held { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { held = false; let ready = waiters; waiters = []; ready.forEach { $0.resume() } }
    var waiting: Int { waiters.count }
}
private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    try FileHandle.standardOutput.write(contentsOf:data + Data([10]))
}
private func syntheticImage() -> CGImage {
    let context = CGContext(data:nil,width:400,height:200,bitsPerComponent:8,bytesPerRow:0,
                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red:0.2,green:0.4,blue:0.6,alpha:1))
    context.fill(CGRect(x:0,y:0,width:400,height:200))
    return context.makeImage()!
}

@main struct NativeToolsHTTPFixture {
    static func main() async throws {
        // Must precede VoiceFlowPaths, service construction, logs and sockets.
        do { try QALaunchIsolation.validate() }
        catch {
            FileHandle.standardError.write(Data("Native tools fixture requires an isolated configuration root.\n".utf8))
            exit(78)
        }
        // The packaged-conversation test supplies its own synthetic gateway.
        // Keep the default closed port for the standalone broker tests.
        let gatewayOrigin: String
        if let candidate = ProcessInfo.processInfo.environment["ATIKA_FIXTURE_GATEWAY_ORIGIN"] {
            guard let url = URLComponents(string: candidate), url.scheme == "http",
                  url.host == "127.0.0.1", let port = url.port, port > 0,
                  url.user == nil, url.password == nil, url.path.isEmpty,
                  url.query == nil, url.fragment == nil else {
                throw T3NativeAuthorityError.unavailable
            }
            gatewayOrigin = candidate
        } else {
            gatewayOrigin = "http://127.0.0.1:1"
        }
        let workspaceRoot: String
        if let candidate = ProcessInfo.processInfo.environment["ATIKA_FIXTURE_WORKSPACE_ROOT"] {
            guard candidate.hasPrefix("/"),
                  !candidate.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw T3NativeAuthorityError.unavailable
            }
            workspaceRoot = candidate
        } else {
            workspaceRoot = "~/isolated-workspace"
        }
        let state = FixtureState(), gate = EffectGate()
        let environment = T3AuthorityEnvironmentIdentity(environmentID:"fixture-native-environment",generation:UUID())
        let leaseBinding = T3NativeAuthorityBinding(ownerId:"fixture-native-owner",deviceId:"fixture-native-device",
                                                   homeId:"fixture-native-home",identityGeneration:UUID().uuidString)
        let nativeEnvironment = T3NativeToolEnvironment(environmentId:environment.environmentID,launchGeneration:environment.generation)
        let binding = T3NativeToolBinding(environment:nativeEnvironment,ownerId:leaseBinding.ownerId,deviceId:leaseBinding.deviceId,
                                          homeId:leaseBinding.homeId,identityGeneration:leaseBinding.identityGeneration)
        let computer = T3NativeComputerPrimitives(capture:{
            .init(displayId:9,bounds:CGRect(x:-800,y:200,width:800,height:400),image:syntheticImage())
        },geometry:{ _ in CGRect(x:-800,y:200,width:800,height:400) },cursor:{ CGPoint(x:-400,y:400) },perform:{ _,checkpoint in
            await gate.enter()
            try checkpoint.check()
            state.effect() // injected sink; never CGEvent/post, screen access or GUI
        })
        let primitives = T3NativeToolPrimitives(binding:binding,computer:computer,overlays:nil,captured:nil)
        let tools = try T3NativeToolCatalog.tools(computer:true,captured:false,overlay:false)
        let configuration = try T3NativeConfiguration(binding:binding, settings:.init(
            runCommands:false, reachNetwork:false, assistantComputerUse:true,
            workspaceRoots:[workspaceRoot], egressAllow:[], egressBlock:["blocked.example"],
            dailyBudgetUSD:0.25, model:"deepseek/deepseek-v4.1-flash", reasoningEffort:""),
            decisions:.init(contextRead:.allow, editWorkspace:.deny, shell:.deny))
        let service = try T3NativeToolService(binding:binding,backendRevision:"synthetic-native-fixture-v1",policyRevision:configuration.policyRevision,tools:tools,
            backend:.init(authority:{ _,action in
                guard state.current else { return nil }
                return .init(binding:binding,backendRevision:"synthetic-native-fixture-v1",policyRevision:configuration.policyRevision,
                             decision:action == .control ? .ask : .allow)
            },perform:{ call,operation,checkpoint in
                state.start()
                do {
                    let result = try await primitives.execute(call,operation,checkpoint)
                    state.finish(result.isError != true); return result
                } catch { state.finish(false); throw error }
            }))
        let sdk = T3NativeToolMCP(service:service,environment:nativeEnvironment,configuration:{
            guard state.current else { throw T3NativeAuthorityError.unavailable }; return configuration
        },onTurnClosed:{ thread,turn in
            await primitives.closeTurn(threadId:thread,turnId:turn)
        })
        let broker = T3NativeAuthorityBroker(ownedEnvironment:{
            guard state.current else { throw T3NativeAuthorityError.unavailable }; return environment
        },leaseProvider:{ owned in
            guard state.current, owned == environment else { throw T3NativeAuthorityError.unavailable }
            return .init(environment:environment,binding:leaseBinding,gatewayOrigin:gatewayOrigin,
                         accessToken:"synthetic-fixture-token-never-production",expiresAt:Date().addingTimeInterval(3600))
        },isCurrent:{ lease in state.current && lease.environment == environment && lease.binding == leaseBinding },
        tools:.init(handle:{ request,owned in
            await sdk.handle(request,ownedEnvironment:.init(environmentId:owned.environmentID,launchGeneration:owned.generation))
        },revoke:{ state.revoke(); sdk.revoke() },stop:{ await gate.release(); await sdk.stop() }))
        let bootstrap = try await broker.start()
        // Private stdio capability transfer to the test harness only. Never log
        // this line or put it in process args, diagnostics, renderer or env.
        try emit(["version":1,"nativeAuthority":["origin":bootstrap.origin,"credential":bootstrap.credential],
                  "environmentId":environment.environmentID,"launchGeneration":environment.generation.uuidString,
                  "binding":["ownerId":leaseBinding.ownerId,"deviceId":leaseBinding.deviceId,"homeId":leaseBinding.homeId,
                             "identityGeneration":leaseBinding.identityGeneration]])
        do {
            while let line = await Task.detached(operation: { readLine() }).value {
                guard line.utf8.count <= 4096, let bytes = line.data(using:.utf8),
                      let input = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                      let op = input["op"] as? String else { throw T3NativeAuthorityError.unavailable }
                switch op {
                case "stats": var result = state.stats(); result["op"] = op; result["waiting"] = await gate.waiting; try emit(result)
                case "hold": await gate.hold(); try emit(["op":op,"ok":true])
                case "release": await gate.release(); try emit(["op":op,"ok":true])
                case "revoke": state.revoke(); sdk.revoke(); await broker.invalidate(); await gate.release(); try emit(["op":op,"ok":true])
                case "stop":
                    state.revoke(); sdk.revoke(); await gate.release(); await broker.stop()
                    try emit(["op":op,"ok":true]); return
                default: throw T3NativeAuthorityError.unavailable
                }
            }
        } catch {
            state.revoke(); sdk.revoke(); await gate.release(); await broker.stop()
            throw error
        }
        state.revoke(); sdk.revoke(); await gate.release(); await broker.stop()
    }
}
