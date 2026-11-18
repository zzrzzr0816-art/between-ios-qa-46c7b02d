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

try checkPersistence()
checkOwnership()
try checkLegacyAndExpiry()
print("Native local state regression checks passed")
