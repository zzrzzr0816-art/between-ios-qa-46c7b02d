final class FeedStub: URLProtocol {
    static var requests: [String] = []
    static var failOffset: Int?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let params = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
        let lang = params.first { $0.name == "language" }!.value!
        let offset = Int(params.first { $0.name == "offset" }!.value!)!
        Self.requests.append("\(lang):\(offset)")
        let status = offset == Self.failOffset ? 503 : 200
        let time = Date().timeIntervalSince1970*1000
        func story(_ id: String, created: Double) -> [String: Any] {
            ["id": id,"text": id,"created":created,"answers":[]]
        }
        let items: [[String: Any]]
        let next: Any
        switch offset {
        case 0: items = [story("first",created:time),story("first",created:time)]; next = 10
        case 10: items = [story("first",created:time),story("expired",created:time-90_000_000)]; next = 20
        default: items = [story("next",created:time)]; next = 20
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:["stories":items,"next_offset":next]))
        client?.urlProtocolDidFinishLoading(self)
    }
}
@MainActor func verify() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FeedStub.self]
    let feed = NativeFeedModel(session:URLSession(configuration:config))
    let loaded = await feed.load("en")
    precondition(loaded && feed.sourceStories.map(\.id) == ["first"])
    FeedStub.failOffset = 0
    let switched = await feed.load("zh")
    precondition(!switched && feed.nextOffset == 10)
    FeedStub.failOffset = 20
    let firstAttempt = await feed.loadNext()
    precondition(!firstAttempt && feed.pageError && feed.nextOffset == 20)
    FeedStub.failOffset = nil
    let retry = await feed.loadNext()
    precondition(retry && !feed.pageError && feed.nextOffset == nil)
    precondition(feed.sourceStories.map(\.id) == ["first","next"])
    precondition(FeedStub.requests == ["en:0","zh:0","en:10","en:20","en:20"])
    precondition(NativeStory(id:"future",text:"future",created:Double.greatestFiniteMagnitude,answers:[]).hoursRemaining() == 24)
    print("Feed regression passed: deduplication, empty pages, failed language switch, retry and cursor")
}
await verify()
