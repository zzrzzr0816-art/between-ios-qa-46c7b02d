import SwiftUI

struct NativeReply: Codable { let id: String?; let author: String; let text: String }
struct NativeAnswer: Codable, Identifiable {
    let id: String
    let author: String
    let side: String
    let text: String
    var likes: Int
    var replies: [NativeReply]
}
struct NativeStory: Codable, Identifiable {
    let id: String
    let text: String
    var detail: String? = nil
    let created: Double
    var answers: [NativeAnswer]

    func hoursRemaining(at now: Double = Date().timeIntervalSince1970) -> Int {
        let remaining = (created/1000+86400-now)/3600
        guard remaining.isFinite else { return 0 }
        return Int(min(24,max(0,ceil(remaining))))
    }
}
struct NativeLocalState: Codable {
    var localStories: [NativeStory] = []
    var snapshots: [NativeStory] = []
    var reports: [String] = []
    var hidden: [String] = []
    var liked: [String: Bool] = [:]
    var best: [String: String] = [:]
    var updates: [String: [String]] = [:]
    var replies: [String: [NativeReply]] = [:]
    var myAnswers: [String: [NativeAnswer]] = [:]
    var reviewed: [String]? = nil
    var storyExpiry: [String: Double]? = nil
    var replyStory: [String: String]? = nil
    var answerOwnership: Set<String>? = nil
    var replyOwnership: Set<String>? = nil

    mutating func rememberExpiry(of story: NativeStory) {
        var expiry = storyExpiry ?? [:]
        expiry[story.id] = story.created/1000+86400
        storyExpiry = expiry
    }

    mutating func visibleStories(merging sourceStories: [NativeStory], at now: Double) -> ([NativeStory], Bool) {
        let originals = localStories + sourceStories
        var changed = false
        var visible: [NativeStory] = []
        for var story in originals where story.created/1000+86400 > now {
            let originals = story.answers
            let originalIDs = Set(originals.map(\.id))
            if let saved = myAnswers[story.id] {
                let owned = saved.filter { !originalIDs.contains($0.id) }
                if owned.count != saved.count { myAnswers[story.id] = owned; changed = true }
                let known = answerOwnership ?? []
                let ids = known.subtracting(originalIDs).union(owned.map(\.id))
                if ids != known { answerOwnership = ids; changed = true }
                if !owned.isEmpty && storyExpiry?[story.id] == nil { rememberExpiry(of: story); changed = true }
                var visibleAnswerIDs = originalIDs
                story.answers.append(contentsOf: owned.filter { visibleAnswerIDs.insert($0.id).inserted })
            }
            for index in story.answers.indices {
                let answer = story.answers[index]
                guard let saved = replies[answer.id] else { continue }
                let source = originals.first { $0.id == answer.id }?.replies ?? []
                let originalReplyIDs = Set(source.compactMap(\.id))
                let local = saved.filter { reply in
                    guard let id = reply.id else { return false }
                    return !originalReplyIDs.contains(id)
                }
                if local.count != saved.count { replies[answer.id] = local; changed = true }
                let known = replyOwnership ?? []
                let verified = known.subtracting(originalReplyIDs)
                if known != verified { replyOwnership = verified; changed = true }
                if !local.isEmpty && replyStory?[answer.id] == nil {
                    var parents = replyStory ?? [:]
                    parents[answer.id] = story.id
                    replyStory = parents
                    rememberExpiry(of: story)
                    changed = true
                }
                var ids = Set(answer.replies.compactMap(\.id))
                story.answers[index].replies.append(contentsOf: local.filter { reply in
                    reply.id.map { ids.insert($0).inserted } ?? false
                })
            }
            if !hidden.contains(story.id) { visible.append(story) }
        }
        return (visible, changed)
    }

    mutating func renameOwnedContent(to name: String) {
        let answersOwned = answerOwnership ?? []
        let repliesOwned = replyOwnership ?? []
        myAnswers = myAnswers.mapValues { answers in
            answers.map { answer in
                guard answersOwned.contains(answer.id) else { return answer }
                return NativeAnswer(id:answer.id,author:name,side:answer.side,text:answer.text,likes:answer.likes,replies:answer.replies)
            }
        }
        replies = replies.mapValues { replies in
            replies.map { reply in
                guard let id = reply.id, repliesOwned.contains(id) else { return reply }
                return NativeReply(id:id,author:name,text:reply.text)
            }
        }
    }

    mutating func migrateLocalStories() -> Bool {
        var changed = false
        for index in localStories.indices where !localStories[index].answers.isEmpty {
            let story = localStories[index]
            var saved = myAnswers[story.id] ?? []
            var ids = Set(saved.map(\.id))
            for answer in story.answers where ids.insert(answer.id).inserted { saved.append(answer) }
            answerOwnership = (answerOwnership ?? []).union(story.answers.map(\.id))
            myAnswers[story.id] = saved
            localStories[index].answers = []
            changed = true
        }
        return changed
    }

    mutating func prune(at now: Double, expiredStoryIDs: Set<String> = []) -> Bool {
        var expiry = storyExpiry ?? [:]
        for story in localStories + snapshots { expiry[story.id] = story.created/1000+86400 }
        let expired = expiredStoryIDs.union(expiry.filter { $0.value <= now }.keys)
        guard !expired.isEmpty else { return false }
        var parents = replyStory ?? [:]
        let answerIDs = Set(expired.flatMap { id in (myAnswers[id] ?? []).map(\.id) })
        let replyKeys = Set(parents.filter { expired.contains($0.value) }.keys).union(answerIDs)
        answerOwnership?.subtract(answerIDs)
        for id in replyKeys {
            replyOwnership?.subtract((replies[id] ?? []).compactMap(\.id))
            replies[id] = nil; parents[id] = nil; liked[id] = nil
        }
        for id in expired { myAnswers[id] = nil; updates[id] = nil; expiry[id] = nil }
        best = best.filter { key, _ in !expired.contains(String(key.prefix { $0 != "|" })) }
        localStories.removeAll { expired.contains($0.id) }
        snapshots.removeAll { expired.contains($0.id) }
        hidden.removeAll { expired.contains($0) }
        storyExpiry = expiry
        replyStory = parents
        return true
    }
}
enum NativeLocalStorage {
    static let legacyGuestKey = "native.local.v1"
    private static let recoverySuffix = ".recovery"
    private struct Recovery: Codable {
        let bytes: Data
        let created: Double
    }

    static func load(from store: UserDefaults, key: String, useLegacyGuest: Bool,
                     now: Double = Date().timeIntervalSince1970) -> (state: NativeLocalState, recoveredUnreadableData: Bool) {
        let recoveryKey = key + recoverySuffix
        if let blob = store.data(forKey:recoveryKey),
           let archive = try? JSONDecoder().decode(Recovery.self,from:blob),
           now-archive.created >= 86400 {
            store.removeObject(forKey:recoveryKey)
        }
        let current = store.data(forKey:key)
        if let current, let state = try? JSONDecoder().decode(NativeLocalState.self,from:current) {
            return (state,false)
        }
        let legacy = useLegacyGuest ? store.data(forKey:legacyGuestKey) : nil
        if let unreadable = current ?? legacy,
           (try? JSONDecoder().decode(NativeLocalState.self,from:unreadable)) == nil,
           store.data(forKey:recoveryKey) == nil,
           let archive = try? JSONEncoder().encode(Recovery(bytes:unreadable,created:now)) {
            store.set(archive,forKey:recoveryKey)
            if store.data(forKey:recoveryKey) == archive {
                store.removeObject(forKey:current == nil ? legacyGuestKey : key)
            }
        }
        if let legacy, let state = try? JSONDecoder().decode(NativeLocalState.self,from:legacy) {
            store.set(legacy,forKey:key)
            if store.data(forKey:key) == legacy { store.removeObject(forKey:legacyGuestKey) }
            return (state,current != nil)
        }
        return (NativeLocalState(),current != nil || legacy != nil)
    }

    static func remove(from store: UserDefaults, key: String) {
        store.removeObject(forKey:key)
        store.removeObject(forKey:key+recoverySuffix)
    }
}

struct NativeFeed: Decodable { let stories: [NativeStory]; let next_offset: Int? }
enum NativeCamp: String {
    case devil, angel
    var accent: Color { Color(hex: self == .devil ? 0xc6786d : 0x628fa9) }
    var background: Color { Color(hex: self == .devil ? 0xfff2ef : 0xeef8ff) }
    var sign: CGFloat { self == .angel ? -1 : 1 }
}
@MainActor final class NativeFeedModel: ObservableObject {
    @Published var stories: [NativeStory] = []
    @Published var loading = false
    @Published var error = false
    @Published var index = 0
    @Published var nextOffset: Int? = nil
    @Published var loadingMore = false
    @Published var pageError = false
    private(set) var loadedLanguage: String?
    private var revision = 0
    private let session: URLSession
    private let apiBase: String

    init(session: URLSession = .shared, apiBase: String = BetweenAPI.base) {
        self.session = session
        self.apiBase = apiBase
    }
    private(set) var sourceStories: [NativeStory] = []
    var current: NativeStory? { stories.indices.contains(index) ? stories[index] : nil }
    var preview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-preview-fixture")
        #else
        return false
        #endif
    }
    @discardableResult
    func load(_ language: String) async -> Bool {
        revision += 1; let version = revision
        loadingMore = false
        pageError = false
        if preview {
            loadedLanguage = language
            sourceStories = Self.fixtures(language)
            return true
        }
        loading = true; error = false
        defer { if version == revision { loading = false } }
        do {
            let result = try await fetchPage(language:language,offset:0)
            guard version == revision, !Task.isCancelled else { return false }
            var ids = Set<String>()
            sourceStories = result.stories.filter { story in
                story.hoursRemaining() > 0 && !story.id.isEmpty && ids.insert(story.id).inserted
            }
            loadedLanguage = language
            nextOffset = result.next_offset.flatMap { $0 > 0 ? $0 : nil }
            return true
        } catch {
            if version == revision && !Task.isCancelled { self.error = true }
            return false
        }
    }
    func loadNext() async -> Bool {
        guard !preview, let offset = nextOffset, let language = loadedLanguage, !loadingMore, !loading else { return false }
        let version = revision
        loadingMore = true
        pageError = false
        defer { if version == revision { loadingMore = false } }
        do {
            var cursor = offset
            var seen = Set(sourceStories.map(\.id))
            for _ in 0..<5 {
                let result = try await fetchPage(language:language,offset:cursor)
                guard version == revision, !Task.isCancelled else { return false }
                let next = result.next_offset.flatMap { $0 > cursor ? $0 : nil }
                let additions = result.stories.filter { story in
                    story.hoursRemaining() > 0 && !story.id.isEmpty && seen.insert(story.id).inserted
                }
                nextOffset = next
                if !additions.isEmpty {
                    sourceStories.append(contentsOf:additions)
                    return true
                }
                guard let next else { return false }
                cursor = next
            }
            return false
        } catch {
            if version == revision && !Task.isCancelled { pageError = true }
            return false
        }
    }

    private func fetchPage(language: String, offset: Int) async throws -> NativeFeed {
        guard let base = URL(string:apiBase), base.host != nil,
              var url = URLComponents(url:base.appendingPathComponent("stories"),resolvingAgainstBaseURL:false) else {
            throw URLError(.badURL)
        }
        url.queryItems = [URLQueryItem(name:"language",value:language),URLQueryItem(name:"scope",value:"feed"),URLQueryItem(name:"offset",value:String(offset))]
        guard let endpoint = url.url else { throw URLError(.badURL) }
        let request = URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15)
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(NativeFeed.self,from:data)
    }

    static func fixtures(_ language:String,created:Double = Date().timeIntervalSince1970*1000) -> [NativeStory] {
        let zh = language == "zh"
        let titles = zh ? ["最好的朋友要搬去另一座城市了。我该告诉他，我其实很难过吗？","毕业后大家好像都有方向，只有我还不知道自己想过什么样的生活。","如果一个选择没有标准答案，我到底该听理智的，还是听自己的？","朋友每次约见面都迟到。我该直接告诉他这让我不舒服吗？","我想给自己放个周末，做家务和回消息却一直占满时间。我应该从哪件事开始拒绝？"] : ["My best friend is moving away. Do I tell them how much it hurts?","Everyone seems to have a plan after graduation. I still have no idea what kind of life I want.","When there is no right answer, do I trust my head or follow what I actually want?","My friend is always late when we meet. Should I tell them how it makes me feel?","I want one weekend to rest, but chores and messages always fill it. Where do I start saying no?"]
        return titles.enumerated().map { i,text in
            var answers = [
                NativeAnswer(id:"a\(i)",author:zh ? "小满":"Mia",side:"angel",text:zh ? "可以告诉他你会想念他，也约定下次见面的时间。难过和为他开心可以同时存在。":"Tell them you will miss them, and make a plan to stay close. You can be happy for them and sad about the distance at the same time.",likes:2,replies:[]),
                NativeAnswer(id:"d\(i)",author:zh ? "阿岸":"Rowan",side:"devil",text:zh ? "想说就说。装作没事并不会让告别好过一点，别等人走了才把真心话发给聊天框。":"Say it now. Pretending you are fine will not make the goodbye easier. Do not save the honest part for a message after they have already left.",likes:1,replies:[])
            ]
            if i >= 3 {
                let angel = i == 3
                    ? (zh ? "选个不赶时间的时候，说清楚你在意的是一直等，可以一起约一个更现实的时间。" : "Pick a quiet moment. Explain that waiting is hard for you, then agree on a time that works for both of you.")
                    : (zh ? "先留出两小时给自己，再决定哪些消息可以等到周一回。" : "Block out two hours for yourself, then pick which messages can wait until Monday.")
                let devil = i == 3
                    ? (zh ? "直接说下次只等十五分钟，之后就按自己的安排走。" : "Say you'll wait fifteen minutes next time, then go ahead with your own plans.")
                    : (zh ? "从关掉一个群的提醒开始。有些事不在周末做，也不会出什么问题。" : "Mute one group chat. Some things can sit untouched until the weekend is over.")
                answers = [
                    NativeAnswer(id:"a\(i)",author:zh ? "小满":"Mia",side:"angel",text:angel,likes:0,replies:[]),
                    NativeAnswer(id:"d\(i)",author:zh ? "阿岸":"Rowan",side:"devil",text:devil,likes:0,replies:[])
                ]
            }
            if i == 1 { answers.append(NativeAnswer(id:"extra-devil",author:zh ? "青禾":"June",side:"devil",text:zh ? "先试一件你真的好奇的事。别人有计划不代表你必须照着走。":"Try one thing you are actually curious about. Someone else's plan does not have to become your deadline.",likes:0,replies:[])) }
            return NativeStory(id:"fixture-\(i)",text:text,created:created,answers:answers)
        }
    }
}
