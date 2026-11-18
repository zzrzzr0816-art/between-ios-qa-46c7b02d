import SwiftUI
import Combine
import UIKit

enum PageDrag: Equatable {
    case openComments, feed, returnFromComments, detailHandle, scrollComments, readStory
}

struct ContentView: View {
    @StateObject var model = NativeFeedModel()
    @StateObject var auth = AuthManager()
    @AppStorage("native.language") var language = "en"
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State var camp: NativeCamp? = nil
    @State var campProgress: CGFloat = 0
    @State var axis: PageDrag?
    @State var verticalTarget: String?
    @State private var pendingFeedRefresh = false
    @State private var transitionRevision = 0
    @State var verticalProgress: CGFloat = 0
    @State var verticalSign: CGFloat = -1
    @State private var readingBounds = CGRect.null
    @State private var readingContent = CGRect.null
    @State var edgeOffset: CGFloat = 0
    @State var settling = false
    @GestureState var feedDragging = false
    @GestureState var returningFromComments = false
    @GestureState var draggingDetailHandle = false
    @State private var toastTask: Task<Void, Never>?
    @State private var hintTask: Task<Void, Never>?
    @State var composer = ""
    @State var discussionID: String?
    @State var localState = NativeLocalState()
    var discussionStory: NativeStory? {
        model.stories.first { $0.id == discussionID }
    }
    var ownedAnswerIDs: Set<String> {
        localState.answerOwnership ?? []
    }
    @State var utility: String? = nil
    @State var selectedReply: NativeAnswer? = nil
    @State var replyText = ""
    @State var writeText = ""
    @State var updateText = ""
    @FocusState var writingFocused: Bool
    @State var snapshots: [NativeStory] = []
    @State var reports: [String] = []
    @State var hidden: [String] = []
    @State var liked: [String:Bool] = [:]
    @State var best: [String:String] = [:]
    @State var updates: [String:[String]] = [:]
    @State var detailStory: NativeStory? = nil
    @State var reportReason = "harassment"
    @State var keyboardHeight: CGFloat = 0
    @State var toastText: String? = nil
    @State var writePeek: NativeCamp = .devil
    @State private var writeBuddyPosition: CGPoint?
    @State private var writeBuddyDragOrigin: CGPoint?
    @State var hintVisible = false
    @State var guideVisible = false
    @State var composerHeight: CGFloat = 48
    @State var replyHeight: CGFloat = 46
    @State var likePulse: [String: Bool] = [:]
    @State var reportType = "story"
    @State var reportId = ""
    @State var reportStoryId: String?
    @State var reportFrom: String? = nil
    @State var snapshotStory: NativeStory? = nil
    @State var reviewed: [String] = []
    @State var loginPrompt: String? = nil
    @State var nicknameMode = false
    @State var nicknameDraft = ""
    @State var nicknameError: String? = nil
    @State var confirmDeleteAccount = false
    private static let expiryTimer = Timer.publish(every:1,on:.main,in:.common).autoconnect()
    @AppStorage("native.motion") var motionOn = true
    @State var composerFocused = false
    @State var replyFocused = false
    @FocusState var nicknameFocused: Bool
    var zh: Bool { language == "zh" }
    func l(_ a:String,_ b:String)->String { zh ? a:b }
    var transitionAnimation: Animation? { (reduceMotion || !motionOn) ? nil:H5Design.settling }
    var devilCount:Int { (discussionID == nil ? model.current : discussionStory)?.answers.filter { $0.side == "devil" }.count ?? 0 }
    var angelCount:Int { (discussionID == nil ? model.current : discussionStory)?.answers.filter { $0.side == "angel" }.count ?? 0 }
    var myName:String { auth.account?.nickname ?? l("你 · 预览","You · preview") }
    var localKey:String { auth.localStorageKey }
    func requireLogin(_ reason:String)->Bool {
        guard auth.isReady else {
            composerFocused = false
            replyFocused = false
            writingFocused = false
            withAnimation(transitionAnimation){loginPrompt=reason}
            return false
        }
        return true
    }
    var body: some View {
        GeometryReader { proxy in
            let top = proxy.safeAreaInsets.top, bottom = proxy.safeAreaInsets.bottom
            let w = proxy.size.width, h = proxy.size.height+top+bottom
            let feedHeight = max(1,h-265)
            ZStack(alignment:.topLeading) {
                H5Design.background
                ZStack(alignment:.topLeading){
                    homeHeader(width:w,top:top)
                    feed(width:w,area:feedHeight).position(x:w/2,y:100+feedHeight/2)
                    idleHints(width:w,height:h,bottom:bottom)
                    bottomNav(width:w,height:h,bottom:bottom)
                }.frame(width:w,height:h)
                if let chosen = camp {
                    Color(hex:0x302532).opacity(0.12*Double(campProgress)).allowsHitTesting(false).zIndex(detailStory != nil ? 22.5:0.5)
                    comments(chosen,width:w,height:h,top:top,bottom:bottom).offset(x:-chosen.sign*w*(1-campProgress)).allowsHitTesting((campProgress>0.99 || axis==.returnFromComments || axis==.scrollComments) && !settling && axis != .openComments && axis != .detailHandle).zIndex(detailStory != nil ? 23:2)
                }
                companions(width:w,top:top,height:h).zIndex(companionsLayer)
                if utility != nil {
                    Color(hex:0x302532).opacity(0.40).zIndex(utility == "report" ? 29.5 : 5).contentShape(Rectangle()).onTapGesture{closeUtility()}.transition(.opacity)
                }
                if let page = utility {
                    utilityPage(page,width:w,height:h,top:top,bottom:bottom).id(page).zIndex(page == "report" ? 30 : 10).transition(pageTransition(page))
                }
                if let answer = selectedReply { replyOverlay(answer,width:w,height:h,top:top,bottom:bottom).zIndex(27).transition(.scale(scale:0.94,anchor:.bottomTrailing).combined(with:.opacity)) }
                if let story = detailStory { detailPage(story,width:w,height:h,top:top,bottom:bottom).zIndex(22).transition(.scale(scale:0.96).combined(with:.opacity)) }
                if detailStory != nil {
                    detailHandles(width:w,height:h).zIndex(26)
                        .allowsHitTesting(utility != "report" && !settling && (camp == nil || axis == .detailHandle))
                }
                if let story = snapshotStory { snapshotPage(story,width:w,height:h,top:top,bottom:bottom).zIndex(22).transition(.opacity) }
                if guideVisible { guideCard(width:w,bottom:bottom).zIndex(29) }
                if let reason = loginPrompt { loginPromptCard(reason,width:w,height:h,top:top,bottom:bottom).zIndex(31) }
                if nicknameMode { nicknameSheet(width:w,height:h,top:top,bottom:bottom).zIndex(32) }
                #if DEBUG
                if keyboardHeight > 0 && ProcessInfo.processInfo.arguments.contains("-ui-verify-companions") {
                    Text("QA keyboard visible").font(.system(size:1)).foregroundColor(.clear).allowsHitTesting(false)
                }
                #endif
                if let text = toastText { toastView(text,bottom:bottom).zIndex(33) }
            }.frame(width:w,height:h).clipped().offset(y:-top)
        }.ignoresSafeArea(.keyboard).foregroundColor(H5Design.ink).tint(H5Design.ink).buttonStyle(.plain)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ui-zh") { language = "zh" }
                #endif
                let initialLanguage = language
                restoreLocal()
                await model.load(initialLanguage)
                rebuildVisibleStories()
                applyPreviewRoute()
                resetIdleHints()
                scheduleGuide()
            }
            .task { await auth.bootstrap() }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task { await auth.bootstrap() }
                }
            }
            .onDisappear {
                hintTask?.cancel()
                toastTask?.cancel()
            }
            .onChange(of: auth.userId){ _ in
                let resumeAction = loginPrompt != nil && auth.account != nil
                reloadLocalForAccount(resumingAction: resumeAction)
                if auth.account != nil {withAnimation(transitionAnimation){loginPrompt=nil}}
                nicknameDraft=auth.account?.nickname ?? ""
                nicknameError=nil
            }
            .onChange(of: axis) { _ in applyPendingFeedRefresh() }
            .onChange(of: feedDragging) { active in
                guard !active else { return }
                DispatchQueue.main.async {
                    guard !feedDragging, !settling else { return }
                    if axis == .openComments { settleCamp(to: 0) }
                    if axis == .feed { settleFeed(to: nil) }
                    if axis == .readStory { axis = nil }
                }
            }
            .onChange(of: returningFromComments) { active in
                guard !active else { return }
                DispatchQueue.main.async {
                    guard !returningFromComments, !settling else { return }
                    if axis == .returnFromComments { settleCamp(to: 1) }
                    if axis == .scrollComments { axis = nil }
                }
            }
            .onChange(of: draggingDetailHandle) { active in
                guard !active else { return }
                DispatchQueue.main.async {
                    if !draggingDetailHandle && axis == .detailHandle && !settling { settleCamp(to: 0) }
                }
            }
            .onReceive(Self.expiryTimer){ _ in pruneExpired() }
            .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                      let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .flatMap(\.windows).first(where: { $0.isKeyWindow }) else { return }
                let overlap = window.bounds.intersection(window.convert(frame, from: window.screen.coordinateSpace))
                let height = !overlap.isNull && overlap.maxY >= window.bounds.maxY-1 ? overlap.height : 0
                updateKeyboardHeight(height,notification:note)
            }
            .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillHideNotification)) { note in
                updateKeyboardHeight(0,notification:note)
            }
    }
    private func updateKeyboardHeight(_ height: CGFloat, notification: Notification) {
        guard height != keyboardHeight else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        withAnimation(reduceMotion ? nil : .easeInOut(duration:duration)) { keyboardHeight = height }
    }
    func applyPreviewRoute(){
        #if DEBUG
        let args=ProcessInfo.processInfo.arguments
        if args.contains(where: { ["-ui-comments","-ui-drag","-ui-reply"].contains($0) }) { discussionID = model.current?.id }
        if args.contains("-ui-profile") {utility = "profile"}
        if args.contains("-ui-write") {utility = "write"}
        if args.contains("-ui-more") {utility = "more"}
        if args.contains("-ui-comments") {camp = .angel; campProgress = 1}
        if args.contains("-ui-drag") {camp = .angel; campProgress = 0.55}
        if args.contains("-ui-reply") {camp = .angel; campProgress = 1; selectedReply = discussionStory?.answers.first{$0.side=="angel"}}
        if args.contains("-ui-detail") {detailStory = model.current}
        #endif
    }
    func toast(_ text:String){
        toastTask?.cancel()
        withAnimation(transitionAnimation) { toastText = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(transitionAnimation) { toastText = nil }
        }
    }
    func toastView(_ text:String,bottom:CGFloat)->some View {
        Text(text).font(.system(size:12)).foregroundColor(.white).padding(.horizontal,18).padding(.vertical,11)
            .background(Color(hex:0x443a43),in:Capsule()).fixedSize()
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom).padding(.bottom,120+bottom).allowsHitTesting(false)
            .transition(.opacity)
    }
    func reloadLocalForAccount(resumingAction: Bool = false){
        let previousStory = model.current?.id
        let previousDiscussion = discussionID
        let previousReply = selectedReply?.id
        if axis != nil || settling {
            transitionRevision += 1
            axis = nil; settling = false; verticalTarget = nil; verticalProgress = 0; edgeOffset = 0
        }
        snapshots=[];reports=[];hidden=[];liked=[:];best=[:];updates=[:];reviewed=[]
        restoreLocal()
        let restoredIndex = previousStory.flatMap { id in model.stories.firstIndex { $0.id == id } }
        model.index = restoredIndex ?? 0
        replyFocused = false
        composerFocused = false
        writingFocused = false
        snapshotStory = nil
        likePulse = [:]
        if resumingAction, previousDiscussion == nil || discussionStory != nil {
            detailStory = detailStory.flatMap { detail in model.stories.first { $0.id == detail.id } }
            selectedReply = discussionStory?.answers.first { $0.id == previousReply }
        } else {
            composer = ""
            replyText = ""
            updateText = ""
            selectedReply = nil
            detailStory = nil
            camp = nil
            discussionID = nil
            campProgress = 0
            if !resumingAction { writeText = "" }
            if utility == "report" { closeReport() }
        }
    }
    func loadNextStories() async {
        if await model.loadNext() {
            pendingFeedRefresh = true
            applyPendingFeedRefresh()
        }
    }
    func applyPendingFeedRefresh() {
        guard pendingFeedRefresh, axis == nil, !settling else { return }
        pendingFeedRefresh = false
        rebuildVisibleStories()
    }
    func restoreLocal() {
        let store = UserDefaults.standard
        let data = store.data(forKey:localKey) ?? (auth.account == nil && !auth.isPreview ? store.data(forKey:"native.local.v1") : nil)
        localState = data.flatMap { try? JSONDecoder().decode(NativeLocalState.self,from:$0) } ?? NativeLocalState()
        let migrated = localState.migrateLocalStories()
        let pruned = localState.prune(at: Date().timeIntervalSince1970)
        snapshots = localState.snapshots
        reports = localState.reports
        hidden = localState.hidden
        liked = localState.liked
        best = localState.best
        updates = localState.updates
        reviewed = localState.reviewed ?? []
        rebuildVisibleStories()
        if migrated || pruned { persistLocal() }
    }
    func rebuildVisibleStories() {
        let previous = model.current?.id
        let now = Date().timeIntervalSince1970
        let (visible, changed) = localState.visibleStories(merging: model.sourceStories, at: now)
        model.stories = visible
        model.index = previous.flatMap { id in visible.firstIndex { $0.id == id } }
            ?? min(model.index,max(0,visible.count-1))
        if let id = discussionID, !visible.contains(where: { $0.id == id }) {
            camp = nil; campProgress = 0; discussionID = nil
            composer = ""; replyText = ""; selectedReply = nil
            composerFocused = false; replyFocused = false
        }
        if let detail = detailStory {
            detailStory = visible.first { $0.id == detail.id }
        }
        if changed { persistLocal() }
    }
    func renameLocalAuthor(to name: String) {
        localState.renameOwnedContent(to: name)
        rebuildVisibleStories()
        persistLocal()
    }
    func rememberExpiry(of story: NativeStory) {
        localState.rememberExpiry(of: story)
    }
    func persistLocal() {
        localState.snapshots=snapshots;localState.reports=reports;localState.hidden=hidden
        localState.liked=liked;localState.best=best;localState.updates=updates;localState.reviewed=reviewed
        if let data=try? JSONEncoder().encode(localState) { UserDefaults.standard.set(data,forKey:localKey) }
    }
    func homeHeader(width:CGFloat,top:CGFloat)->some View {
        ZStack(alignment:.topLeading) {
            (Text("between").foregroundColor(Color(hex:0x42353f))+Text(".").foregroundColor(Color(hex:0xe0776e))).font(.system(size:23,weight:.heavy)).tracking(-1.5).frame(height:42).position(x:69,y:top+37)
            HStack(spacing:7){
                Button(zh ? "中文":"EN"){
                    guard !settling, axis == nil else { return }
                    guard !model.loading else { return }
                    let requested = zh ? "en" : "zh"
                    Task {
                        if await model.load(requested) {
                            language = requested
                            rebuildVisibleStories()
                        } else {
                            toast(l("语言切换失败，请重试","Couldn’t switch languages. Try again."))
                        }
                    }
                }.accessibilityLabel("Switch language")
                Button {
                    guard !model.loading, !settling, axis == nil else { return }
                    withAnimation(transitionAnimation){utility="more"}
                } label:{Text("•••")}.accessibilityLabel(l("更多","More"))
            }.font(.system(size:14)).buttonStyle(HeaderButtonStyle()).position(x:width-67.5,y:top+37)
        }.opacity((1-Double(campProgress)) * (utility == "write" ? 0:1)).allowsHitTesting(campProgress<0.01 && utility != "write")
    }
    func feed(width:CGFloat,area:CGFloat)->some View {
        ZStack {
            if let story=model.current {
                let cardH=H5Design.cardHeight(story.text,width:width,available:area)
                let next=verticalTarget.flatMap { id in model.stories.first { $0.id == id } }
                let nextH=next.map {H5Design.cardHeight($0.text,width:width,available:area)} ?? cardH
                let travel=H5Design.verticalTravel(area:area,current:cardH,next:nextH)
                ForEach([story] + (next.map { [$0] } ?? [])) { item in
                    let current = item.id == story.id
                    storyCard(item,width:width,height:current ? cardH : nextH,interactive:current)
                        .scaleEffect(current ? 1-0.025*campProgress : 1)
                        .modifier(StorySlide(progress:verticalProgress,travel:travel*verticalSign,edgeOffset:edgeOffset,isCurrent:current))
                        .offset(x:current ? (camp?.sign ?? 0)*width*0.3*campProgress : 0)
                        .allowsHitTesting(current && !settling)
                        .accessibilityHidden(!current)
                }
                if model.index >= model.stories.count-1 && (model.loadingMore || model.pageError) {
                    Group {
                        if model.loadingMore { ProgressView() }
                        else { Button(l("加载失败，点此重试","Loading failed. Tap to retry.")) { Task { await loadNextStories() } } }
                    }.font(.system(size:12)).padding(10).background(H5Design.card,in:Capsule())
                        .frame(maxHeight:.infinity,alignment:.bottom).padding(.bottom,12)
                }
                Text("\(model.index+1) / \(model.stories.count)").font(.system(size:11)).tracking(2).foregroundColor(Color(hex:0x8c787f)).rotationEffect(.degrees(90)).position(x:width-30,y:area/2)
            } else if model.loading {ProgressView().tint(H5Design.muted)}
            else {
                VStack(spacing:14) {
                    Text(model.error ? l("暂时无法加载","Could not load stories") : l("暂时没有烦恼","No more stories to show"))
                        .font(.system(size:24,weight:.bold))
                    if model.loadingMore { ProgressView().tint(H5Design.muted) }
                    else if model.error {
                        Button(l("重试","Retry")) { Task { if await model.load(language) { rebuildVisibleStories() } } }
                    } else if model.nextOffset != nil {
                        Button(model.pageError ? l("重试加载","Retry loading") : l("继续加载","Load more")) { Task { await loadNextStories() } }
                    }
                }.padding(30).background(H5Design.card,in:RoundedRectangle(cornerRadius:30))
            }
        }.frame(width:width,height:area).contentShape(Rectangle())
            .onPreferenceChange(StoryReadingBounds.self) { readingBounds = $0 }
            .onPreferenceChange(StoryReadingContent.self) { readingContent = $0 }
            .simultaneousGesture(DragGesture(minimumDistance:8,coordinateSpace:.global)
                .updating($feedDragging) { _, active, _ in active = true }
                .onChanged { feedChanged($0,width:width,area:area) }
                .onEnded { feedEnded($0,width:width,area:area) })
            .mask(LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.black,location:0.07),.init(color:.black,location:0.93),.init(color:.clear,location:1)],startPoint:.top,endPoint:.bottom))
    }
    func feedChanged(_ value:DragGesture.Value,width:CGFloat,area:CGFloat){
        guard !settling, utility == nil, selectedReply == nil, detailStory == nil,
              snapshotStory == nil, loginPrompt == nil, let story = model.current else { return }
        if axis == nil {
            guard camp == nil, !model.loading else { return }
            resetIdleHints()
            if abs(value.translation.width) > abs(value.translation.height) {
                axis = .openComments
                discussionID = story.id
            } else {
                let reading = readingBounds.contains(value.startLocation) && !readingContent.isNull
                let canRead = value.translation.height > 0
                    ? readingContent.minY < readingBounds.minY-2
                    : readingContent.maxY > readingBounds.maxY+2
                axis = reading && canRead ? .readStory : .feed
            }
        }
        if axis == .openComments {
            if value.translation.width != 0 {
                camp = value.translation.width < 0 ? .devil : .angel
            }
            campProgress = min(1,abs(value.translation.width)/max(1,width))
        } else if axis == .feed {
            let sign: CGFloat = value.translation.height < 0 ? -1 : 1
            let target = model.index + (sign < 0 ? 1 : -1)
            if model.stories.indices.contains(target) {
                verticalSign = sign
                verticalTarget = model.stories[target].id
                let a = H5Design.cardHeight(story.text,width:width,available:area)
                let b = H5Design.cardHeight(model.stories[target].text,width:width,available:area)
                verticalProgress = H5Design.verticalProgress(raw:value.translation.height,travel:H5Design.verticalTravel(area:area,current:a,next:b))
                edgeOffset = 0
            } else {
                verticalTarget = nil
                verticalProgress = 0
                edgeOffset = sign*32*(1-exp(-abs(value.translation.height)/100))
            }
        }
    }
    func feedEnded(_ value:DragGesture.Value,width:CGFloat,area:CGFloat){
        if axis == .readStory { axis = nil; return }
        guard !settling, axis == .openComments || axis == .feed else { return }
        feedChanged(value,width:width,area:area)
        if axis == .openComments {
            settleCamp(to: abs(value.translation.width) > max(65,width*0.23) ? 1 : 0)
        } else if let target = verticalTarget, let next = model.stories.first(where: { $0.id == target }), let story = model.current {
            let a = H5Design.cardHeight(story.text,width:width,available:area)
            let b = H5Design.cardHeight(next.text,width:width,available:area)
            let travel = H5Design.verticalTravel(area:area,current:a,next:b)
            let distance = value.translation.height * verticalSign
            let prediction = value.predictedEndTranslation.height * verticalSign
            let commit = distance > max(65,travel*0.16) || (distance > 35 && prediction > travel*0.5)
            settleFeed(to: commit ? next.id : nil, releaseBoost: max(0,prediction-distance)/max(1,travel))
        } else {
            if value.translation.height < -55, model.index >= model.stories.count-1 {
                if model.nextOffset != nil || model.loadingMore {
                    Task { await loadNextStories() }
                } else {
                    toast(l("这是最后一条啦","You’re all caught up"))
                }
            }
            settleFeed(to: nil)
        }
    }
    func settleCamp(to progress: CGFloat) {
        let returning = axis == .returnFromComments || (axis == nil && campProgress > 0)
        let duration = returning ? 0.30 : 0.34
        let animation = transitionAnimation == nil ? nil : Animation.timingCurve(0.22,1,0.36,1,duration:duration)
        settle(duration: duration, animation: animation, changes: { campProgress = progress }) {
            if progress == 0 { camp = nil; discussionID = nil; composer = ""; replyText = "" }
            resetIdleHints()
        }
    }
    func settleFeed(to id: String?, releaseBoost: CGFloat = 0) {
        let remaining = abs((id == nil ? 0 : 1)-verticalProgress)
        let duration = verticalTarget == nil ? 0.30 : max(0.32,min(0.54,0.36+Double(remaining)*0.21-Double(min(releaseBoost,1))*0.065))
        let animation = transitionAnimation == nil ? nil : Animation.timingCurve(0.18,0.85,0.24,1,duration:duration)
        settle(duration: duration, animation: animation, changes: {
            verticalProgress = id == nil ? 0 : 1
            edgeOffset = 0
        }) {
            if let id, let index = model.stories.firstIndex(where: { $0.id == id }) {
                model.index = index
                if index >= model.stories.count-2 { Task { await loadNextStories() } }
            }
            verticalTarget = nil
            verticalProgress = 0
            resetIdleHints()
        }
    }
    func settle(duration: Double, animation: Animation?, changes: () -> Void, finished: @escaping () -> Void) {
        settling = true
        transitionRevision += 1
        let revision = transitionRevision
        withAnimation(animation,changes)
        let complete = {
            guard revision == transitionRevision else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                finished()
                axis = nil
                settling = false
            }
        }
        if animation == nil { complete() }
        else { DispatchQueue.main.asyncAfter(deadline:.now()+duration,execute:complete) }
    }
    func storyCard(_ story:NativeStory,width:CGFloat,height:CGFloat,interactive:Bool = false)->some View {
        let hours = story.hoursRemaining()
        let long = story.text.count > 180
        return VStack(spacing:0){
            Text("✦").font(.system(size:27)).foregroundColor(Color(hex:0xd7958c)).frame(height:32).padding(.top,34)
            if long {
                ScrollView(.vertical,showsIndicators:false){
                    Text(story.text).font(.system(size:H5Design.titleSize(width),weight:.bold)).tracking(-0.8).lineSpacing(max(0,H5Design.titleSize(width)*1.35-UIFont.systemFont(ofSize:H5Design.titleSize(width),weight:.bold).lineHeight)).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity)
                        .background {
                            if interactive {
                                GeometryReader { proxy in
                                    Color.clear.preference(key:StoryReadingContent.self,value:proxy.frame(in:.global))
                                }
                            }
                        }
                }.frame(maxHeight:H5Design.titleSize(width)*4.05)
                    .background {
                        if interactive {
                            GeometryReader { proxy in
                                Color.clear.preference(key:StoryReadingBounds.self,value:proxy.frame(in:.global))
                            }
                        }
                    }.padding(.top,20)
                Text(l("上下拖动阅读全文","Drag to read")).font(.system(size:11)).foregroundColor(H5Design.muted).padding(.top,8)
            } else {
                Text(story.text).font(.system(size:H5Design.titleSize(width),weight:.bold)).tracking(-0.8).lineSpacing(max(0,H5Design.titleSize(width)*1.35-UIFont.systemFont(ofSize:H5Design.titleSize(width),weight:.bold).lineHeight)).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.top,20).frame(maxWidth:.infinity)
            }
            if let detail = story.detail, !detail.isEmpty {
                Text(detail).font(.system(size:15)).foregroundColor(Color(hex:0x5e5259)).lineSpacing(max(0,15*1.65-UIFont.systemFont(ofSize:15).lineHeight)).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.top,12).frame(maxWidth:370).frame(maxHeight:UIScreen.main.bounds.height*0.24,alignment:.top).clipped()
            }
            if let update = updates[story.id]?.last, !update.isEmpty {
                Text(l("后续进展","Update")+" · "+update).font(.system(size:12)).foregroundColor(Color(hex:0x816e75)).multilineTextAlignment(.center).lineLimit(2).padding(.top,14).frame(maxWidth:330)
            }
            Text("◷ \(hours) \(l("小时后消失","hours left"))  ·  \(story.answers.count) \(l("条建议","responses"))").font(.system(size:12)).foregroundColor(H5Design.muted).padding(.top,18).padding(.bottom,34)
        }.padding(.horizontal,26).frame(width:width-52,height:height).clipped().background(H5Design.card,in:RoundedRectangle(cornerRadius:30))
            .overlay(RoundedRectangle(cornerRadius:30).stroke(Color.white.opacity(0.79),lineWidth:1)).overlay(RoundedRectangle(cornerRadius:24).stroke(Color.white.opacity(0.67),lineWidth:1).padding(7)).shadow(color:Color(hex:0xa46872).opacity(0.17),radius:24,x:0,y:20).shadow(color:Color(hex:0x896d7b).opacity(0.08),radius:6,x:0,y:4)
            .contentShape(RoundedRectangle(cornerRadius:30))
            .onTapGesture {if interactive && axis == nil && !settling && camp == nil {openDetail(story)}}
    }
    func pageTransition(_ page:String)->AnyTransition {
        page == "write" || page == "more"
            ? .move(edge:.bottom).combined(with:.opacity)
            : .opacity.combined(with:.scale(scale:0.985))
    }
    func openDetail(_ story:NativeStory){
        guard !model.loading, let i=model.stories.firstIndex(where:{$0.id==story.id}) else { return }
        model.index=i
        withAnimation(transitionAnimation){detailStory=story}
    }
    func companions(width:CGFloat,top:CGFloat,height:CGFloat)->some View {
        let strong = abs(devilCount-angelCount) > 1
        let mode = companionMode
        let interactive = scenePhase == .active && !settling && keyboardHeight == 0 && camp == nil && axis == nil
            && !composerFocused && !writingFocused && !replyFocused && !nicknameFocused
            && detailStory == nil && snapshotStory == nil && loginPrompt == nil && !nicknameMode && !guideVisible
            && (utility == nil || utility == "write" || mode == .library)
        let place = CompanionPlacement(width:width,top:top,height:height,mode:mode,panelProgress:campProgress,fromDetail:detailStory != nil)
        return ZStack(alignment:.topLeading) {
            companion(.devil,placement:place,mode:mode,interactive:interactive,width:width,top:top,height:height,strong:strong)
            companion(.angel,placement:place,mode:mode,interactive:interactive,width:width,top:top,height:height,strong:strong)
        }
            .animation(axis == .returnFromComments || camp != nil || selectedReply != nil || settling ? nil:transitionAnimation,value:place)
    }
    private func companion(_ side: NativeCamp, placement: CompanionPlacement, mode: CompanionMode,
                           interactive: Bool, width: CGFloat, top: CGFloat, height: CGFloat, strong: Bool) -> some View {
        let angel = side == .angel
        let visible = angel ? placement.angelVisible : placement.devilVisible
        let writing = mode == .write(side)
        let base = CGPoint(x:angel ? placement.angelX : placement.devilX,y:placement.y)
        let resting = writing ? (writeBuddyPosition ?? base) : base
        let position = writing && keyboardHeight > 0
            ? CGPoint(x:width-93,y:H5Design.writeSheetTop(height:height,keyboard:keyboardHeight,safeTop:top)+34) : resting
        let scale = companionScale(side,placement:placement) * (writing && keyboardHeight > 0 ? 0.82 : 1)
        let parkedAtEdge = writing && writeBuddyPosition != nil && writeBuddyDragOrigin == nil
            && (resting.x <= 31 || resting.x >= width-31)
        let touchWidth: CGFloat = parkedAtEdge ? 28 : mode == .library ? 38 : 67
        let touchOffset = parkedAtEdge ? (resting.x < width/2 ? -16 : 16)/scale : 0
        let canTouch = interactive && visible && motionOn && !reduceMotion
        let move: ((CGSize,Bool) -> Void)? = writing ? { delta, ended in
            moveWritingCompanion(from:base,by:delta,ended:ended,width:width,top:top,height:height)
        } : nil
        return CompanionRig(angel:angel,cheer:(angel ? angelCount>devilCount : devilCount>angelCount) ? 1:0,
                            reply:(angel ? angelCount<devilCount : devilCount<angelCount) ? 1:0,strong:strong,chinese:zh,
                            motionOn:motionOn,dragLeft:max(0,base.x-40)/scale,dragRight:max(0,width-base.x-40)/scale,
                            dragUp:max(0,base.y-top-38)/scale,dragDown:max(0,height-base.y-38)/scale,
                            touchWidth:touchWidth,touchOffsetX:touchOffset,interactive:canTouch,context:mode,
                            storyID:discussionID ?? detailStory?.id ?? model.current?.id,moveWithFinger:move,cancelMove:writing ? { cancelWritingCompanionMove() } : nil)
            .scaleEffect(scale).position(position)
            .opacity(visible ? companionOpacity(side) : 0)
            .allowsHitTesting(canTouch)
            .overlay(alignment:.topLeading) {
                companionProbe(side,visible:visible && companionOpacity(side)>0.05)
                    .position(position)
            }
    }
    private func moveWritingCompanion(from base: CGPoint, by delta: CGSize, ended: Bool,
                                     width: CGFloat, top: CGFloat, height: CGFloat) {
        let origin = writeBuddyDragOrigin ?? writeBuddyPosition ?? base
        if writeBuddyDragOrigin == nil { writeBuddyDragOrigin = origin }
        let edge: CGFloat = 30
        let right = max(edge,width-edge)
        let upper = top+edge
        let lower = max(upper,height-edge)
        let point = CGPoint(x:min(right,max(edge,origin.x+delta.width)),y:min(lower,max(upper,origin.y+delta.height)))
        if ended {
            let candidates = [CGPoint(x:edge,y:point.y), CGPoint(x:right,y:point.y), CGPoint(x:point.x,y:upper)]
            withAnimation(transitionAnimation) {
                writeBuddyPosition = candidates.min {
                    hypot($0.x-point.x,$0.y-point.y) < hypot($1.x-point.x,$1.y-point.y)
                }
            }
            writeBuddyDragOrigin = nil
        } else {
            writeBuddyPosition = point
        }
    }
    private func cancelWritingCompanionMove() {
        if let origin = writeBuddyDragOrigin {
            withAnimation(transitionAnimation) { writeBuddyPosition = origin }
            writeBuddyDragOrigin = nil
        }
    }

    @ViewBuilder private func companionProbe(_ side: NativeCamp, visible: Bool) -> some View {
        #if DEBUG
        if visible && ProcessInfo.processInfo.arguments.contains("-ui-verify-companions") {
            Text("QA \(side.rawValue) companion")
                .font(.system(size:1)).foregroundColor(.clear)
                .frame(width:20,height:20)
                .accessibilityLabel("QA \(side.rawValue) companion")
                .allowsHitTesting(false)
        }
        #else
        EmptyView()
        #endif
    }

    private func companionScale(_ side: NativeCamp, placement: CompanionPlacement) -> CGFloat {
        let emphasis = camp == side ? H5Design.buddyCampScale*campProgress : 0
        return placement.scale*(placement.buddyScale+emphasis)/H5Design.buddyBaseScale
    }
    private func companionOpacity(_ side: NativeCamp) -> Double {
        camp != nil && camp != side ? Double(1-campProgress) : 1
    }

    var companionMode:CompanionMode {
        if camp != nil { return .comments }
        if detailStory != nil { return .detail }
        if utility == "write" { return .write(writePeek) }
        if utility == "profile" { return .profile }
        if let u = utility, ["profile-stories","profile-answers","saved","activity"].contains(u) { return .library }
        return .home
    }
    var companionsLayer:Double {
        if selectedReply != nil { return 28 }
        if detailStory != nil { return 25 }
        if utility == "write" { return 11 }
        if utility == "more" || utility == "report" || utility == "update" { return 4 }
        if utility != nil { return 11 }
        if camp != nil { return 12 }
        return 1
    }
    func bottomNav(width:CGFloat,height:CGFloat,bottom:CGFloat)->some View {
        HStack(spacing:0){navItem(l("烦恼","Stories"),icon:"house",active:true){goHome()};navItem(l("发布","Post"),icon:"plus",active:false){openWrite()};navItem(l("我的","Me"),icon:"person",active:false){
            guard !settling, axis == nil, camp == nil else { return }
            withAnimation(transitionAnimation){utility="profile"}
        }}.padding(.horizontal,24).padding(.bottom,bottom).frame(width:width,height:70+bottom).background(ZStack{BlurView();Color(hex:0xfff8fc).opacity(0.53)}).overlay(Rectangle().fill(Color.white.opacity(0.5)).frame(height:1),alignment:.top).position(x:width/2,y:height-(70+bottom)/2)
    }
    func goHome(){
        guard !settling, axis == nil else { return }
        resetInputFocus()
        replyText=""
        composer = ""
        discussionID = nil
        withAnimation(transitionAnimation){utility=nil;detailStory=nil;selectedReply=nil;camp=nil;campProgress=0}
        resetIdleHints()
    }
    func closeUtility(){
        if utility == "report" { closeReport(); return }
        resetInputFocus()
        withAnimation(transitionAnimation){utility=nil}
        resetIdleHints()
    }
    private func resetInputFocus() {
        writingFocused = false
        replyFocused = false
        composerFocused = false
        nicknameFocused = false
    }
    func openWrite(){
        guard !settling, axis == nil, camp == nil else { return }
        writePeek = Bool.random() ? .devil:.angel
        writeBuddyPosition = nil
        writeBuddyDragOrigin = nil
        resetIdleHints()
        withAnimation(transitionAnimation){utility="write"}
    }
    func scheduleGuide(){
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-verify-companions") { return }
        #endif
        guard !UserDefaults.standard.bool(forKey:"native.guide.v1") else{return}
        DispatchQueue.main.asyncAfter(deadline:.now()+1.8){
            guard camp == nil,utility == nil,detailStory == nil,selectedReply == nil else{return}
            withAnimation(.easeOut(duration:0.35)){guideVisible=true}
        }
    }
    func dismissGuide(){
        UserDefaults.standard.set(true,forKey:"native.guide.v1")
        withAnimation(.easeOut(duration:0.25)){guideVisible=false}
    }
    func guideCard(width:CGFloat,bottom:CGFloat)->some View {
        VStack(alignment:.leading,spacing:5){
            Text(l("第一次来？","New here?")).font(.system(size:15,weight:.bold))
            Text(l("上下滑动看烦恼，左右滑动选择天使或恶魔，进入评论区再分享你的想法。","Swipe up or down for stories. Swipe left or right to choose a side and share your thoughts.")).font(.system(size:14)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            Text(l("匿名交流 · 烦恼、评论和收藏在 24 小时后删除","Anonymous · Stories, replies and saves expire after 24 hours")).font(.system(size:11)).foregroundColor(Color(hex:0x917e80)).padding(.top,2)
        }.foregroundColor(Color(hex:0x514348)).padding(.leading,17).padding(.trailing,38).padding(.vertical,15)
            .frame(width:min(340,width-36),alignment:.leading)
            .background(Color(hex:0xfffaf8).opacity(0.96),in:RoundedRectangle(cornerRadius:21))
            .overlay(RoundedRectangle(cornerRadius:21).stroke(Color.white.opacity(0.85),lineWidth:1))
            .shadow(color:Color(hex:0x5a4348).opacity(0.18),radius:16,y:10)
            .overlay(Button(action:dismissGuide){Text("×").font(.system(size:24,weight:.light)).foregroundColor(Color(hex:0x78676a)).frame(width:38,height:38)}.padding(.trailing,2).padding(.top,2),alignment:.topTrailing)
            .padding(.bottom,bottom+88).frame(width:width).frame(maxHeight:.infinity,alignment:.bottom)
            .transition(.move(edge:.bottom).combined(with:.opacity))
    }
    func detailHandles(width:CGFloat,height:CGFloat)->some View {
        let y = height*0.46+29
        return ZStack{
            detailHandle(.devil,width:width,y:y)
            detailHandle(.angel,width:width,y:y)
        }.frame(width:width,height:height).allowsHitTesting(true)
    }
    func detailHandle(_ side:NativeCamp,width:CGFloat,y:CGFloat)->some View {
        let sign:CGFloat = side == .devil ? 1:-1
        return Rectangle().fill(Color.white.opacity(0.001)).frame(width:64,height:140)
            .contentShape(Rectangle())
            .position(x: side == .devil ? 15:width-15, y:y)
            .highPriorityGesture(DragGesture(minimumDistance:6,coordinateSpace:.global).updating($draggingDetailHandle) { _, active, _ in active = true }.onChanged{value in
                guard selectedReply == nil, !settling else{return}
                let drag = value.translation.width*sign
                if drag > 0 || axis == .detailHandle {
                    axis = .detailHandle
                    discussionID = detailStory?.id
                    camp = side
                    campProgress = min(1,max(0,drag/max(1,width)))
                }
            }.onEnded { value in
                guard axis == .detailHandle, !settling else { return }
                let drag = value.translation.width*sign
                settleCamp(to: drag > max(65,width*0.23) ? 1 : 0)
            })
            .onTapGesture {withAnimation(transitionAnimation){discussionID=detailStory?.id;camp=side;campProgress=1}}
    }
    func pruneExpired() {
        guard axis == nil, !settling else { return }
        let now = Date().timeIntervalSince1970
        let expired = Set((model.stories + snapshots + [detailStory,snapshotStory].compactMap { $0 })
            .filter { $0.created/1000+86400 <= now }.map(\.id))
        let previous = model.current?.id
        var pruned = localState
        guard pruned.prune(at: now, expiredStoryIDs: expired) else { return }
        localState = pruned
        snapshots = localState.snapshots
        hidden = localState.hidden
        liked = localState.liked
        best = localState.best
        updates = localState.updates
        if let id = discussionID, expired.contains(id) {
            camp = nil; campProgress = 0; discussionID = nil
            selectedReply = nil; composer = ""; replyText = ""
            composerFocused = false; replyFocused = false
        }
        if let previous, expired.contains(previous), utility == "more" || utility == "update" {
            utility = nil; updateText = ""; writingFocused = false
        }
        if let detailStory, expired.contains(detailStory.id) { self.detailStory = nil }
        if let snapshotStory, expired.contains(snapshotStory.id) { self.snapshotStory = nil }
        rebuildVisibleStories()
        persistLocal()
    }
    func resetIdleHints(_ delay:Double = 4.2){
        hintTask?.cancel()
        hintVisible = false
        hintTask = Task { @MainActor in
            var wait = delay
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                wait = 12
                guard camp == nil, utility == nil, selectedReply == nil, detailStory == nil,
                      snapshotStory == nil, axis == nil, !settling, !guideVisible else { continue }
                withAnimation(transitionAnimation) { hintVisible = true }
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(transitionAnimation) { hintVisible = false }
            }
        }
    }
    func idleHints(width:CGFloat,height:CGFloat,bottom:CGFloat)->some View {
        let show = hintVisible && camp == nil && utility == nil && selectedReply == nil && !settling && verticalProgress < 0.001
        return HStack(spacing:8){
            Text("← " + l("恶魔","Devil"))
            Spacer(minLength:8)
            Text("↑ " + l("下一个","Next"))
            Spacer(minLength:8)
            Text(l("天使","Angel") + " →")
        }.font(.system(size:11)).foregroundColor(Color(hex:0x6e5964)).padding(.horizontal,26).frame(width:width).opacity(show ? 0.68:0).offset(y:show ? 0:4).position(x:width/2,y:height-bottom-94.5).allowsHitTesting(false)
    }
    func navItem(_ title:String,icon:String,active:Bool,action:@escaping ()->Void)->some View {
        let post = icon == "plus"
        let kind:NavGlyph.Kind = post ? .plus : icon == "person" ? .person : .house
        let color = Color(hex: active ? 0x6c4c58 : 0x8d8085)
        return Button(action:action){
            VStack(spacing:3){
                ZStack{
                    RoundedRectangle(cornerRadius: post ? 11:12).fill(post ? Color(hex:0xdf9b90) : active ? Color(hex:0xf6e5e2) : Color.clear)
                    NavGlyph(kind:kind).stroke(post ? Color.white:color, style:StrokeStyle(lineWidth:post ? 2*22/24:1.8*21/24,lineCap:.round,lineJoin:.round)).frame(width:post ? 22:21,height:post ? 22:21)
                }.frame(width:post ? 39:34,height:post ? 30:29)
                Text(title).font(.system(size:11,weight:.semibold)).foregroundColor(color)
            }.frame(maxWidth:.infinity,minHeight:56)
        }
    }
}
private struct BlurView:UIViewRepresentable {
    func makeUIView(context:Context)->UIVisualEffectView { UIVisualEffectView(effect:UIBlurEffect(style:.systemUltraThinMaterial)) }
    func updateUIView(_ view:UIVisualEffectView,context:Context) {}
}
struct PressScale:ButtonStyle {
    func makeBody(configuration:Configuration)->some View { configuration.label.scaleEffect(configuration.isPressed ? 0.95:1).animation(.easeOut(duration:0.12),value:configuration.isPressed) }
}
private struct NavGlyph:Shape {
    enum Kind { case house, plus, person }
    let kind:Kind
    func path(in r:CGRect)->Path {
        let s = r.width/24
        func p(_ x:CGFloat,_ y:CGFloat)->CGPoint { CGPoint(x:x*s,y:y*s) }
        var path = Path()
        switch kind {
        case .house:
            path.move(to:p(4.5,11.2));path.addLine(to:p(12,5));path.addLine(to:p(19.5,11.2));path.addLine(to:p(19.5,18.3))
            path.addQuadCurve(to:p(18.6,19.2),control:p(19.5,19.2));path.addLine(to:p(5.4,19.2))
            path.addQuadCurve(to:p(4.5,18.3),control:p(4.5,19.2));path.closeSubpath()
            path.move(to:p(9.2,19));path.addLine(to:p(9.2,13.6));path.addLine(to:p(14.8,13.6));path.addLine(to:p(14.8,19))
        case .plus:
            path.move(to:p(12,5));path.addLine(to:p(12,19));path.move(to:p(5,12));path.addLine(to:p(19,12))
        case .person:
            path.addEllipse(in:CGRect(x:8.8*s,y:5*s,width:6.4*s,height:6.4*s))
            path.move(to:p(5.6,19));path.addCurve(to:p(12,14.3),control1:p(6.3,16.05),control2:p(8.75,14.3))
            path.addCurve(to:p(18.4,19),control1:p(15.25,14.3),control2:p(17.7,16.05))
        }
        return path
    }
}
enum CompanionMode:Equatable {
    case home
    case comments
    case profile
    case library
    case write(NativeCamp)
    case detail
}
private struct CompanionPlacement:Equatable {
    var devilX:CGFloat = 63
    var angelX:CGFloat = 0
    var y:CGFloat = 0
    var scale:CGFloat = 1
    var buddyScale:CGFloat = 1.15
    var devilVisible = true
    var angelVisible = true
    init(width:CGFloat,top:CGFloat,height:CGFloat,mode:CompanionMode,panelProgress:CGFloat,fromDetail:Bool) {
        switch mode {
        case .home:
            angelX = width-63
            y = top+137
        case .comments:
            angelX = width-63
            y = top+137
            if fromDetail {
                let remaining = 1-panelProgress
                devilX -= 52*remaining
                angelX += 52*remaining
                y += (height*0.46+29-y)*remaining
            }
        case .profile:
            scale = 0.6
            y = top+86
            devilX = width/2-38
            angelX = width/2+38
        case .library:
            scale = 0.53
            y = top+33.4
            devilX = width-51.5
            angelX = width-31.4
        case .write(let side):
            buddyScale = 0.94
            y = max(top+34,height*0.12-16)
            devilX = 61
            angelX = width-61
            devilVisible = side == .devil
            angelVisible = side == .angel
        case .detail:
            devilX = 11
            angelX = width-11
            y = height*0.46+29
        }
    }
}
private struct StorySlide: AnimatableModifier {
    var progress: CGFloat
    let travel: CGFloat
    let isCurrent: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, overscroll) }
        set { progress = newValue.first; overscroll = newValue.second }
    }
    private var overscroll: CGFloat = 0

    init(progress: CGFloat, travel: CGFloat, edgeOffset: CGFloat, isCurrent: Bool) {
        self.progress = progress
        self.travel = travel
        self.overscroll = edgeOffset
        self.isCurrent = isCurrent
    }

    func body(content: Content) -> some View {
        let fraction = max(0,min(1,progress))
        let amount = H5Design.fade(fraction)
        content.offset(y:isCurrent ? travel*fraction+overscroll : -travel*(1-fraction))
            .opacity(Double(isCurrent ? 1-amount : amount))
    }
}
private struct StoryReadingBounds: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}
private struct StoryReadingContent: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}
private struct HeaderButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {configuration.label.frame(width:42,height:42).background(Color.white.opacity(0.47),in:Circle()).scaleEffect(configuration.isPressed ? 0.94:1)}
}
