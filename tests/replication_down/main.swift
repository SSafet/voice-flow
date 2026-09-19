import Foundation

// V9 · the downward half: the turns Atika ran arrive, are adopted once, merge
// their cloud sub-record, fetch the branch (never a checkout, never a merge)
// and leave a returned_to_mac notice; and the restore rule brings back the
// history a store has lost. Design: 06 §3.11 "Down"; 01 §3.6 adopt/restore.

func downJSON(_ down: TPThreadEventDown) -> String {
    String(data: try! JSONEncoder().encode(down), encoding: .utf8)!
}

let world = ReplicationTestWorld()

// ── install ─────────────────────────────────────────────────────────────
replicationExpect(world.channel.registeredDownwardPrefixes == ["thread"],
                  "install registers the owner of each thread's downward stream")

world.store.seedThread(ReplicationFixtures.thread(id: "t1", projectID: "p1", homeID: "home-1"))
world.store.projectList = [ReplicationFixtures.project(id: "p1", homeID: "home-1")]

// ── an adopted event is stored once and never goes up ───────────────────
let cloudItem = ReplicationFixtures.down(threadID: "t1", originSeq: 1,
                                         event: ReplicationFixtures.downItemEvent(threadID: "t1"))
let appendsBefore = world.channel.appends.count
try! world.channel.deliver("thread:t1/atika", kind: "thread.event", bodyJson: downJSON(cloudItem), seq: 1)
replicationExpect((world.store.events["t1"] ?? []).count == 1,
                  "an adopted event is stored with its origin and originSeq")
replicationExpect(world.channel.appends.count == appendsBefore,
                  "an adopted event is never offered back to Atika")

try! world.channel.deliver("thread:t1/atika", kind: "thread.event", bodyJson: downJSON(cloudItem), seq: 1)
replicationExpect((world.store.events["t1"] ?? []).count == 1,
                  "a duplicate adopts nothing and rewrites nothing")

// ── a thread.updated with a cloud sub-record is merged, then fetched ────
let cloudThread = ReplicationFixtures.thread(
    id: "t1",
    projectID: "p1",
    homeID: "home-1",
    cloud: ReplicationFixtures.cloud(model: "gpt-5.6-pro"),
    branch: "atika/fix-cart-3f9a2c",
    version: 4
)
let cloudUpdate = ReplicationFixtures.down(
    threadID: "t1",
    originSeq: 2,
    event: TPDurableEvent(item: nil, thread: cloudThread, threadID: "t1", turn: nil, type: .threadUpdated)
)
try! world.channel.deliver("thread:t1/atika", kind: "thread.event", bodyJson: downJSON(cloudUpdate), seq: 2)

replicationExpect(world.store.mergedClouds.count == 1,
                  "a thread.updated from Atika is merged, not copied")
replicationExpect(world.store.mergedClouds[0].cloud?.model == "gpt-5.6-pro",
                  "the merge takes Atika's cloud sub-record")
replicationExpect(world.store.mergedClouds[0].branch == "atika/fix-cart-3f9a2c",
                  "the merge keeps the branch the cloud turn ran on")

replicationExpect(world.fetcher.fetches.count == 1, "the branch is fetched exactly once")
replicationExpect(world.fetcher.fetches[0].branch == "atika/fix-cart-3f9a2c",
                  "the fetch names the stored branch")
replicationExpect(world.fetcher.fetches[0].path == "/tmp/project",
                  "the fetch runs in the thread's working folder")

replicationExpect(world.store.notices.count == 1, "one returned_to_mac notice is stored")
let notice = world.store.notices[0].event.item?.notice
replicationExpect(notice?.code == .returnedToMAC, "the notice's code is returned_to_mac")
replicationExpect(notice?.git?.branch == "atika/fix-cart-3f9a2c", "the notice names the fetched branch")
replicationExpect(notice?.git?.headCommit == "deadbeef" && notice?.git?.fetched == true,
                  "the notice says the fetch worked and names the head commit")
replicationExpect(world.channel.appends.contains { $0.seq == world.store.notices[0].originSeq },
                  "this Mac's own notice goes up like any other event")

// ── a second cloud turn on the same branch does not fetch twice ─────────
let secondCloud = ReplicationFixtures.down(
    threadID: "t1",
    originSeq: 3,
    event: ReplicationFixtures.downItemEvent(threadID: "t1", itemID: "cloud-i2", text: "more")
)
try! world.channel.deliver("thread:t1/atika", kind: "thread.event", bodyJson: downJSON(secondCloud), seq: 3)
replicationExpect(world.fetcher.fetches.count == 1,
                  "the branch is fetched once per thread and branch, not once per cloud event")

// ── a failed fetch still stores the turns and says so ───────────────────
let errThread = ReplicationFixtures.thread(
    id: "t2",
    projectID: "p1",
    homeID: "home-1",
    cloud: ReplicationFixtures.cloud(),
    branch: "atika/other-111111",
    version: 4
)
world.store.seedThread(errThread)
world.fetcher.result = BranchFetchResult(headCommit: nil, error: "could not resolve host")
let errUpdate = ReplicationFixtures.down(
    threadID: "t2",
    originSeq: 1,
    event: TPDurableEvent(item: nil, thread: errThread, threadID: "t2", turn: nil, type: .threadUpdated)
)
try! world.channel.deliver("thread:t2/atika", kind: "thread.event", bodyJson: downJSON(errUpdate), seq: 1)
replicationExpect((world.store.events["t2"] ?? []).count == 1,
                  "the adopted turns are stored even when git fails")
let failedNotice = world.store.notices.last!.event.item?.notice
replicationExpect(failedNotice?.code == .returnedToMAC, "the notice still appears")
replicationExpect(failedNotice?.git?.fetched == false, "it says the fetch did not work")
replicationExpect(failedNotice?.git?.detail == "could not resolve host", "it carries git's own error")

// ── the restore rule: Atika has more than this Mac does ─────────────────
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t3", originSeq: 1))
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t3", originSeq: 2))
world.store.seedThread(ReplicationFixtures.thread(id: "t3", projectID: "p1", homeID: "home-1"))

try! world.replication.stateMark(stream: "thread:t3", throughSeq: 5)
replicationExpect(world.replication.isBehind(threadID: "t3"),
                  "Atika naming a higher number marks the thread behind")
let requestAppend = world.channel.appends.last { $0.kind == "thread.restore_request" }
replicationExpect(requestAppend != nil, "the Mac asks Atika for what it is missing")
let restore = replicationDecode(TPThreadRestoreRequest.self, requestAppend!.bodyJson!)
replicationExpect(restore.threadID == "t3", "the request names the thread")
replicationExpect(restore.have.contains { $0.origin == "home-1" && $0.lastOriginSeq == 2 },
                  "the request says what this Mac has for each origin")

let beforeBehind = world.channel.appends.count
try! world.replication.stored([ReplicationFixtures.ownEvent(threadID: "t3", originSeq: 3)])
replicationExpect(world.channel.appends.count == beforeBehind,
                  "no new event of a behind thread is offered up until the missing ones arrive")

// this Mac's own lost events come back on the downward stream and clear it
let returned = ReplicationFixtures.down(
    threadID: "t3",
    origin: "home-1",
    originSeq: 5,
    event: ReplicationFixtures.downItemEvent(threadID: "t3", itemID: "own-i5")
)
try! world.channel.deliver("thread:t3/home-1", kind: "thread.event", bodyJson: downJSON(returned), seq: 5)
replicationExpect(!world.replication.isBehind(threadID: "t3"),
                  "once the lost events are adopted the thread catches up")
replicationExpect(world.channel.appends.last?.stream == "thread:t3" && world.channel.appends.last?.seq == 5,
                  "the caught-up thread is offered up from its highest number again")

print("replication_down: all checks passed")
