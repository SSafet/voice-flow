import Foundation

// V9 · the records stream: this Mac's description of itself and its project
// and persona records, sent as a state stream that is always its complete
// current state. Design: 06 §3.11 "Up"; 05 §3.3 state streams; decision 20
// (core memory travels in the persona record).

let world = ReplicationTestWorld()

// ── install ─────────────────────────────────────────────────────────────
replicationExpect(world.channel.registeredStatePrefixes == ["records"],
                  "install registers the owner of the records state stream")

world.store.projectList = [ReplicationFixtures.project(id: "p1", homeID: "self", name: "pantria", version: 1)]
world.store.personaList = [ReplicationFixtures.persona(id: "flora", homeID: "self", version: 1)]

// ── a change appends each record once ───────────────────────────────────
try! world.replication.publishRecords()
replicationExpect(world.channel.appends.count == 3,
                  "a first publish sends the home description, one project and one persona")
replicationExpect(world.channel.appends.allSatisfy { $0.stream == "records" },
                  "every record travels on the records stream")
replicationExpect(Set(world.channel.appends.map(\.kind)) == ["home.describe", "record.project", "record.persona"],
                  "the kinds are branch 01's home.describe, record.project and record.persona")
replicationExpect(world.channel.appends.allSatisfy { $0.bodyJson != nil && $0.seq == nil },
                  "a state stream carries the whole record and lets the outbox number it")

let projectAppend = world.channel.appends.first { $0.kind == "record.project" }!
let project = replicationDecode(TPProject.self, projectAppend.bodyJson!)
replicationExpect(project.id == "p1" && project.version == 1, "the project body is the stored record")
replicationExpect(project.homeID == "home-1",
                  "the item encoder puts the current home id where the store wrote self")

let personaAppend = world.channel.appends.first { $0.kind == "record.persona" }!
let persona = replicationDecode(TPPersona.self, personaAppend.bodyJson!)
replicationExpect(persona.coreMemory == "remember the cart",
                  "the persona record carries the read-only copy of core memory (decision 20)")

// ── a record is always sent in its newest version, and never twice ──────
try! world.replication.publishRecords()
replicationExpect(world.channel.appends.count == 3,
                  "nothing changed, so nothing is appended again")

world.store.personaList = [ReplicationFixtures.persona(id: "flora", homeID: "self", version: 2)]
try! world.replication.publishRecords()
replicationExpect(world.channel.appends.count == 4, "a version rise sends that record once")
replicationExpect(world.channel.appends.last!.kind == "record.persona",
                  "only the record whose version rose is sent")
replicationExpect(replicationDecode(TPPersona.self, world.channel.appends.last!.bodyJson!).version == 2,
                  "it is sent in its newest version")

// ── home.describe is idempotent by value ────────────────────────────────
world.runtimes.describe_ = ReplicationFixtures.homeDescribe(label: "Safet's MacBook Pro")
try! world.replication.publishRecords()
replicationExpect(world.channel.appends.count == 4, "an unchanged description sends nothing")

world.runtimes.describe_ = ReplicationFixtures.homeDescribe(label: "Safet's Mac")
try! world.replication.publishRecords()
replicationExpect(world.channel.appends.count == 5 && world.channel.appends.last!.kind == "home.describe",
                  "a changed label raises one new description")
let describe = replicationDecode(TPHomeDescribe.self, world.channel.appends.last!.bodyJson!)
replicationExpect(describe.label == "Safet's Mac", "the description carries the new label")

// ── the rebuild is the owner's complete current state ───────────────────
let rebuilt = try! world.channel.rebuildState("records")
replicationExpect(rebuilt.count == 3, "the rebuild returns the home and every project and persona")
replicationExpect(rebuilt.map(\.kind).contains("home.describe"), "the rebuild includes the home description")
replicationExpect(rebuilt.filter { $0.kind == "record.project" }.count == 1,
                  "the rebuild includes every project of this home")
replicationExpect(rebuilt.filter { $0.kind == "record.persona" }.count == 1,
                  "the rebuild includes every persona of this home")
replicationExpect(rebuilt.allSatisfy { !$0.sum.isEmpty }, "the rebuild puts a checksum on every item")

print("replication_records: all checks passed")
