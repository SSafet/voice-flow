import Foundation
import GRDB

// The home takeover as the Mac sees it (decision 23, C35): the offer that
// sign-in returns, the fresh email code, the refusal by name on a wrong code,
// the home id the confirmation yields, and what the old Mac experiences when it
// comes back after the takeover.

@main
struct HomeTakeoverTests {
    static func makeIdentity(_ gateway: FakeGateway, _ provider: MemoryKeyProvider,
                             _ pool: DatabasePool) -> DeviceIdentity {
        DeviceIdentity(origin: "https://atika.test", gateway: gateway, keyProvider: provider,
                       database: pool, legacyRefreshTokenStore: nil)
    }

    static func main() async throws {
        let checks = Checks()

        // ---- The offer is exactly what sign-in returned ----------------------
        let gateway = FakeGateway()
        let provider = MemoryKeyProvider()
        let (pool, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let offered = [
            ContinuableHome(homeId: "home-1", label: "Safet's MacBook Pro",
                            deviceLastSeenAt: "2026-09-05T09:00:00.000Z", projectCount: 3, threadCount: 12),
            ContinuableHome(homeId: "home-2", label: "Old iMac",
                            deviceLastSeenAt: nil, projectCount: 0, threadCount: 1),
        ]
        gateway.continuableHomes = offered
        let identity = makeIdentity(gateway, provider, pool)
        try await identity.load()
        let challenge = try await identity.startSignIn(email: "owner@example.test")
        let result = try await identity.completeSignIn(challenge: challenge, code: "123456", label: "Synthetic Mac")
        checks.equal(result.continuableHomes, offered, "sign-in carries the homes to continue verbatim")
        checks.equal(await identity.continuableHomes, offered, "the identity keeps the offered homes")

        // ---- No home qualifies: the Mac offers nothing of its own ------------
        let emptyGateway = FakeGateway()
        let emptyProvider = MemoryKeyProvider()
        let (emptyPool, emptyRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let empty = makeIdentity(emptyGateway, emptyProvider, emptyPool)
        try await empty.load()
        let emptyChallenge = try await empty.startSignIn(email: "owner@example.test")
        let emptyResult = try await empty.completeSignIn(challenge: emptyChallenge, code: "123456",
                                                         label: "Synthetic Mac")
        checks.check(emptyResult.continuableHomes.isEmpty, "no offered home is offered")
        let emptyHomes = await empty.continuableHomes
        checks.check(emptyHomes.isEmpty, "the identity invents no home")

        // ---- A device that is not signed in cannot take a home over ----------
        let strangerGateway = FakeGateway()
        let (strangerPool, strangerRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: strangerRoot) }
        let stranger = makeIdentity(strangerGateway, MemoryKeyProvider(key: nil), strangerPool)
        try await stranger.load()
        do {
            try await stranger.requestTakeoverCode(homeId: "home-1")
            checks.check(false, "a device with no identity must not ask for a takeover code")
        } catch {
            checks.check((error as? DeviceIdentityError) == .notSignedIn,
                         "asking for a code with no identity is notSignedIn")
        }
        checks.equal(strangerGateway.takeoverStarts.count, 0, "nothing is asked of the gateway without an identity")

        // ---- A wrong code is refused by name and changes nothing -------------
        gateway.takeoverCodes["home-1"] = "654321"
        try await identity.requestTakeoverCode(homeId: "home-1")
        checks.equal(gateway.takeoverStarts.count, 1, "the takeover code is requested at that moment")
        checks.equal(gateway.takeoverStarts[0].homeId, "home-1", "the code is for the chosen home")
        checks.equal(gateway.takeoverStarts[0].accessToken, gateway.accessTokenValue,
                     "the code request carries a bearer token")
        let rowBefore = try deviceIdentityRowCount(pool)
        do {
            _ = try await identity.confirmTakeover(homeId: "home-1", code: "000000")
            checks.check(false, "a wrong takeover code must be refused")
        } catch {
            checks.equal(serverCode(error), "takeover_not_confirmed", "a wrong code is takeover_not_confirmed")
        }
        checks.equal(await identity.homeId, nil, "a wrong code leaves no home id")
        checks.equal(try deviceIdentityRowCount(pool), rowBefore, "a wrong code drops no device row")
        checks.check(provider.hasKey, "a wrong code keeps the private key")

        // ---- The right code yields the home id, and it survives a restart ----
        let takeover = try await identity.confirmTakeover(homeId: "home-1", code: "654321")
        checks.equal(takeover.homeId, "home-1", "the confirmation yields the home id")
        checks.equal(gateway.takeoverConfirms.last?.code, "654321", "the confirmation carries the code the person typed")
        checks.equal(gateway.takeoverConfirms.last?.accessToken, gateway.accessTokenValue,
                     "the confirmation carries a bearer token")
        checks.equal(gateway.takeoverConfirms.count, 2, "the refused code and the right one are two calls")
        checks.equal(await identity.homeId, "home-1", "the identity remembers the home")
        var state = await identity.state
        checks.equal(state, .ready, "a completed takeover leaves the device ready")

        let reopened = makeIdentity(gateway, provider, pool)
        try await reopened.load()
        checks.equal(await reopened.homeId, "home-1", "the home id survives a restart")

        // ---- The old Mac comes back: it is revoked ---------------------------
        gateway.revoked = true
        do {
            _ = try await identity.accessToken(force: true)
            checks.check(false, "the taken-over device must not mint a token")
        } catch {
            checks.check((error as? DeviceIdentityError) == .notSignedIn,
                         "the taken-over device ends notSignedIn")
        }
        state = await identity.state
        checks.equal(state, .signedOut(.revoked), "the old Mac reports signed-out with reason revoked")
        checks.check(!provider.hasKey, "the old Mac wipes its private key")
        checks.equal(try deviceIdentityRowCount(pool), 0, "the old Mac drops its device row")

        checks.finish("home takeover")
    }
}
