let now: Double = 100_000
let fresh = now * 1000
let expired = (now - 86400) * 1000

func answer(_ id: String, author: String = "Same name", replies: [NativeReply] = []) -> NativeAnswer {
    NativeAnswer(id: id, author: author, side: "angel", text: id, likes: 0, replies: replies)
}

func story(_ id: String, created: Double = fresh, answers: [NativeAnswer] = []) -> NativeStory {
    NativeStory(id: id, text: id, created: created, answers: answers)
}

func assertAnswers(_ items: [NativeAnswer]?, _ ids: [String]) {
    precondition(items?.map(\.id) == ids)
}

func checkPersistence() throws {
    var state = NativeLocalState()
    state.myAnswers["later"] = [answer("my-later-answer")]
    state.replies["later-answer"] = [NativeReply(id: "my-later-reply", author: "Same name", text: "keep")]
    state.replyStory = ["later-answer": "later"]
    state.rememberExpiry(of: story("later"))

    _ = state.visibleStories(merging: [story("first")], at: now)
    state.liked["first-answer"] = true
    let encoded = try JSONEncoder().encode(state)
    var restored = try JSONDecoder().decode(NativeLocalState.self, from: encoded)
    assertAnswers(restored.myAnswers["later"], ["my-later-answer"])
    precondition(restored.replies["later-answer"]?.first?.id == "my-later-reply")
    let (visible, _) = restored.visibleStories(merging: [story("later", answers: [answer("later-answer")])], at: now)
    assertAnswers(visible.first?.answers, ["later-answer","my-later-answer"])
    precondition(visible.first?.answers.first?.replies.count == 1)
}

func checkOwnership() {
    let remoteReply = NativeReply(id: "foreign-reply", author: "Same name", text: "foreign")
    let ownReply = NativeReply(id: "own-reply", author: "Same name", text: "own")
    let remote = story("shared", answers: [answer("foreign-answer", replies: [remoteReply])])
    var state = NativeLocalState()
    state.myAnswers["shared"] = [answer("foreign-answer"), answer("own-answer")]
    state.replies["foreign-answer"] = [remoteReply, ownReply]
    state.replyOwnership = ["own-reply"]
    _ = state.visibleStories(merging: [remote], at: now)
    state.renameOwnedContent(to: "New name")
    let (visible, _) = state.visibleStories(merging: [remote], at: now)
    assertAnswers(visible.first?.answers, ["foreign-answer","own-answer"])
    let answers = visible[0].answers
    precondition(answers.map(\.author) == ["Same name","New name"])
    precondition(answers[0].replies.map(\.author) == ["Same name","New name"])
    precondition(state.answerOwnership == ["own-answer"])
}

func checkLegacyAndExpiry() throws {
    var state = NativeLocalState()
    state.localStories = [story("local-legacy", created: expired, answers: [answer("embedded")])]
    state.myAnswers["local-legacy"] = [answer("embedded"),answer("another")]
    state.replies["remote-answer"] = [NativeReply(id: "remote-story-reply", author: "Me", text: "expires")]
    state.replyStory = ["remote-answer":"remote-expired"]
    state.storyExpiry = ["remote-expired":now]
    state.liked = ["remote-answer":true]
    state.updates = ["local-legacy":["update"]]
    precondition(state.migrateLocalStories())
    assertAnswers(state.myAnswers["local-legacy"], ["embedded","another"])
    precondition(state.localStories[0].answers.isEmpty)
    precondition(!state.migrateLocalStories())
    precondition(state.prune(at: now))
    let persisted = try JSONDecoder().decode(NativeLocalState.self, from: JSONEncoder().encode(state))
    precondition(persisted.localStories.isEmpty && persisted.myAnswers.isEmpty)
    precondition(persisted.replies.isEmpty && persisted.updates.isEmpty && persisted.liked.isEmpty)
    precondition(persisted.answerOwnership?.isEmpty == true)
    precondition(!state.prune(at: now))
}

func checkCorruptStorageRecovery() throws {
    let suite = "between-qa-" + UUID().uuidString
    guard let store = UserDefaults(suiteName:suite) else { preconditionFailure("Test storage unavailable") }
    defer { store.removePersistentDomain(forName:suite) }
    let key = "guest-v2"
    let unreadable = Data([0xff,0x00,0xab])
    store.set(unreadable,forKey:key)
    var legacy = NativeLocalState()
    legacy.localStories = [story("local-v1")]
    store.set(try JSONEncoder().encode(legacy),forKey:NativeLocalStorage.legacyGuestKey)
    let restored = NativeLocalStorage.load(from:store,key:key,useLegacyGuest:true,now:now)
    precondition(restored.recoveredUnreadableData && restored.state.localStories.first?.id == "local-v1")
    precondition(store.data(forKey:NativeLocalStorage.legacyGuestKey) == nil)
    precondition(store.data(forKey:key+".recovery") != nil)
    let reread = NativeLocalStorage.load(from:store,key:key,useLegacyGuest:false,now:now+86401)
    precondition(!reread.recoveredUnreadableData && reread.state.localStories.first?.id == "local-v1")
    precondition(store.data(forKey:key+".recovery") == nil)
    NativeLocalStorage.remove(from:store,key:key)
    precondition(store.data(forKey:key) == nil)
    store.set(unreadable,forKey:key)
    let empty = NativeLocalStorage.load(from:store,key:key,useLegacyGuest:false,now:now)
    precondition(empty.recoveredUnreadableData && empty.state.localStories.isEmpty)
    precondition(store.data(forKey:key) == nil && store.data(forKey:key+".recovery") != nil)
    NativeLocalStorage.remove(from:store,key:key)
    precondition(store.data(forKey:key+".recovery") == nil)
}

try checkPersistence()
checkOwnership()
try checkLegacyAndExpiry()
try checkCorruptStorageRecovery()
print("Native local state regression checks passed")
