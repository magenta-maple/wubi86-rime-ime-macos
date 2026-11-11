import Foundation

/// 进程内共享的 Rime 会话（输入法扩展生命周期内复用）
final class RimeSession {
    static let shared = RimeSession()

    private let engine = RimeEngineLibrime()
    private let lock = NSRecursiveLock()
    private let phaseLock = NSLock()
    private let startQueue = DispatchQueue(
        label: "cn.kylebing.inputmethod.meifengwubi.rime",
        qos: .userInitiated
    )
    private(set) var started = false

    /// 词库表已经确认存在时，按键过程不再每次 stat。停掉引擎后重新确认。
    private var buildPresent = false

    /// 主线程菜单只读这个，避免部署时再去抢引擎锁。
    private var phase: Phase = .notStarted

    enum Phase: Equatable {
        case notStarted
        case starting
        case compiling
        case deploying
        case ready
        case failed
    }

    /// 状态栏输入法菜单里展示的说明。就绪时为 nil。
    var menuExplanation: String? {
        switch currentPhase() {
        case .notStarted, .starting:
            return "正在启动引擎…"
        case .compiling:
            return "正在编译词库，请稍候…"
        case .deploying:
            return "正在重新部署…"
        case .ready:
            return nil
        case .failed:
            return "引擎未就绪，可尝试「部署」"
        }
    }

    var isBusy: Bool {
        switch currentPhase() {
        case .starting, .compiling, .deploying:
            return true
        default:
            return false
        }
    }

    /// 是否缺少编译产物，需要全量 deploy
    private var needsFullBuild: Bool {
        if buildPresent { return false }
        let exists = tableBinExists()
        if exists { buildPresent = true }
        return !exists
    }

    private func tableBinExists() -> Bool {
        let user = RimeResourceDeployer.resolveUserDataURL()
        let table = user.appendingPathComponent("build/wubi86_jidian.table.bin")
        return FileManager.default.fileExists(atPath: table.path)
    }

    private func currentPhase() -> Phase {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return phase
    }

    private func setPhase(_ newPhase: Phase) {
        phaseLock.lock()
        phase = newPhase
        phaseLock.unlock()
    }

    /// 不阻塞 IMK 主线程：状态栏菜单才能在编译/部署时给出说明。
    func prepareInBackground(forceFullCheck: Bool = false) {
        phaseLock.lock()
        switch phase {
        case .starting, .compiling, .deploying:
            phaseLock.unlock()
            return
        case .ready:
            let should = forceFullCheck || UserDictWriter.peekNeedsDeploy() || !tableBinExists()
            if !should {
                phaseLock.unlock()
                return
            }
        case .notStarted, .failed:
            phase = tableBinExists() ? .starting : .compiling
        }
        phaseLock.unlock()
        startQueue.async { [weak self] in
            _ = self?.ensureStarted(forceFullCheck: forceFullCheck)
        }
    }

    /// 按键路径：拿不到锁或引擎未就绪时立刻返回，避免把输入法菜单卡成灰色。
    func beginInput() -> Bool {
        guard lock.try() else { return false }
        if started, engine.isReady {
            return true
        }
        lock.unlock()
        prepareInBackground()
        return false
    }

    func endInput() {
        lock.unlock()
    }

    @discardableResult
    func ensureStarted(forceFullCheck: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startLockedIfNeeded(forceFullCheck: forceFullCheck)
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        engine.stop()
        started = false
        buildPresent = false
        setPhase(.notStarted)
    }

    /// 造词后重载用户词。走进程内增量部署，不 finalize 正在用的 librime。
    @discardableResult
    func reloadUserDictionary() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        setPhase(.deploying)
        _ = UserDictWriter.consumeNeedsDeploy()
        if started, engine.isReady {
            if engine.redeploy() {
                NSLog("[MeifengWubi] user dict reloaded")
                UserDictAutoSync.noteEngineDidReload()
                setPhase(.ready)
                return true
            }
            NSLog("[MeifengWubi] user dict redeploy failed, restarting")
            engine.noteExternalShutdown()
            started = false
            buildPresent = false
        }
        return startLocked(forceFullCheck: false)
    }

    /// `deployNow` 会 finalize 全局 librime。输入法进程里调用后必须重建，否则菜单还在但按键无效。
    @discardableResult
    func restartAfterExternalDeploy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        setPhase(.deploying)
        _ = UserDictWriter.consumeNeedsDeploy()
        engine.noteExternalShutdown()
        started = false
        buildPresent = false
        return startLocked(forceFullCheck: false)
    }

    /// 同进程全量部署前先结束活动会话，避免 deployer initialize/finalize 破坏仍在使用的引擎。
    func performExternalDeploy<T>(_ operation: () -> T) -> (result: T, restarted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        setPhase(.deploying)
        engine.stop()
        started = false
        buildPresent = false
        let result = operation()
        _ = UserDictWriter.consumeNeedsDeploy()
        engine.noteExternalShutdown()
        return (result, startLocked(forceFullCheck: false))
    }

    private func startLockedIfNeeded(forceFullCheck: Bool) -> Bool {
        let force = forceFullCheck || needsFullBuild
        if started, engine.isReady {
            // 正在打字时先不部署，避免清掉当前编码。标记留到编码结束。
            // 没有待部署标记时不问 librime，避免每次按键都取一遍上下文。
            if UserDictWriter.peekNeedsDeploy() || needsFullBuild {
                let composing = engine.peekSnapshot()?.isComposing == true
                if !composing, UserDictWriter.consumeNeedsDeploy() || needsFullBuild {
                    NSLog("[MeifengWubi] redeploy rime (needsFull=%d)", needsFullBuild)
                    setPhase(.deploying)
                    if !engine.redeploy() {
                        NSLog("[MeifengWubi] automatic redeploy failed, restarting")
                        buildPresent = false
                        started = false
                        return startLocked(forceFullCheck: force)
                    }
                    UserDictAutoSync.noteEngineDidReload()
                    setPhase(.ready)
                }
            }
            setPhase(.ready)
            return true
        }
        return startLocked(forceFullCheck: force)
    }

    private func startLocked(forceFullCheck: Bool) -> Bool {
        setPhase(forceFullCheck || !tableBinExists() ? .compiling : .starting)
        do {
            try engine.start(forceFullCheck: forceFullCheck)
            started = true
            UserDictAutoSync.noteEngineDidReload()
            setPhase(.ready)
            NSLog("[MeifengWubi] rime started forceFull=%d user=%@", forceFullCheck, RimeResourceDeployer.resolveUserDataURL().path)
            return true
        } catch {
            NSLog("[MeifengWubi] Rime start failed: %@", error.localizedDescription)
            started = false
            setPhase(.failed)
            return false
        }
    }

    var bridgeEngine: RimeEngineLibrime { engine }
}
