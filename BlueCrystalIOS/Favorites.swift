import SwiftUI
import UIKit

// MARK: - 我的收藏：记住喜欢的变频 / 手动强度，下次一点就缓缓回到那里。
// 只存 UserDefaults 里的几组数字；召回交给 ManualControlVM.applyFavorite，走手动页同一条发送路径，
// 不新增任何发帧方式，也不碰准入 / 冷却 / 额度 / 看门狗。存取时都按各模式范围夹紧（FavoriteSetting.clamp）。
// 收藏区不弹任何 alert / sheet：重命名是卡片里的输入框、删除可撤销，底部停止键始终在键盘上面可点。
// 界面只有一块：滑杆下面的「我的收藏」——一排卡片点了就回去，行尾「收藏此刻」，「整理」就地重命名 / 删除。

final class FavoriteStore: ObservableObject {
    static let storageKey = "bc.ui.favorites.v1"

    @Published private(set) var items: [FavoriteSetting]

    enum AddResult {
        case added(FavoriteSetting)
        case duplicate(FavoriteSetting)
        case full
        case invalid
    }

    /// 刚删掉的一条和它原来的位置（撤销用）
    struct Removed: Equatable {
        let item: FavoriteSetting
        let index: Int
    }

    init() {
        items = FavoriteCodec.decode(UserDefaults.standard.data(forKey: Self.storageKey))
        // 上次整理到一半被系统杀掉：草稿名字（空的、带首尾空格的、超长的）在这里收好
        finalizeNames()
    }

    var isFull: Bool { items.count >= FavoriteSetting.maxCount }

    func add(mode: BCProtocol.Mode, levels: [Int]) -> AddResult {
        let name = FavoriteSetting.nextName(existing: items.map { $0.name })
        guard let fav = FavoriteSetting.make(name: name, mode: mode, levels: levels) else { return .invalid }
        if let dup = items.first(where: { $0.sameSetting(as: fav) }) { return .duplicate(dup) }
        guard !isFull else { return .full }
        items.append(fav)
        persist()
        return .added(fav)
    }

    @discardableResult
    func remove(_ id: UUID) -> Removed? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = Removed(item: items[i], index: i)
        items.remove(at: i)
        persist()
        return removed
    }

    enum RestoreResult {
        case restored
        /// 已经在了，或同样的手感又收藏过一次：腾出位置也放不回，先于"已满"判断
        case duplicate
        case full
    }

    /// 撤销删除：放回原位；已经在了 / 同样的手感又收藏过一次、或满了就不放
    @discardableResult
    func restore(_ r: Removed) -> RestoreResult {
        if items.contains(where: { $0.id == r.item.id || $0.sameSetting(as: r.item) }) { return .duplicate }
        guard !isFull else { return .full }
        let at: Int = min(max(0, r.index), items.count)
        items.insert(r.item, at: at)
        persist()
        return .restored
    }

    /// 打字过程中：只去掉换行，不截到 12 个字、不去首尾空格。
    /// 中文输入法还没上屏的拼音也会进到这里，按 12 个字截断会把拼音打断（整句拼音打不出来）；
    /// 长度和空白在 finalizeNames 里收（完成、回车、离开页面、下次启动）。草稿只设一个很宽的上限
    func rename(_ id: UUID, to raw: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let flat = raw.components(separatedBy: .newlines).joined()
        let draft = String(flat.prefix(FavoriteSetting.maxDraftLength))
        guard draft != items[i].name else { return }
        items[i].name = draft
        persist()
    }

    /// 整理完成：空名字补上自动名，去掉首尾空白，截到 maxNameLength
    func finalizeNames() {
        var changed = false
        for i in items.indices {
            let others = items.enumerated().filter { $0.offset != i }.map { $0.element.name }
            let fallback = FavoriteSetting.nextName(existing: others)
            let clean = FavoriteSetting.sanitizedName(items[i].name, fallback: fallback)
            if clean != items[i].name {
                items[i].name = clean
                changed = true
            }
        }
        if changed { persist() }
    }

    func match(mode: BCProtocol.Mode, levels: [Int]) -> FavoriteSetting? {
        guard mode != .skill else { return nil }
        let current = FavoriteSetting.clamp(levels, maxLevel: mode.maxLevel)
        return items.first { $0.modeRaw == mode.rawValue && $0.clampedLevels == current }
    }

    private func persist() {
        UserDefaults.standard.set(FavoriteCodec.encode(items), forKey: Self.storageKey)
    }
}

// MARK: - 我的收藏（滑杆下面）：一排卡片 + 行尾「收藏此刻」，整理就地展开

/// 手感页唯一的收藏区：点卡片召回、点行尾的加号卡片收藏此刻、「整理」就地重命名 / 删除（可撤销）。
/// 卡片能不能点由 FavoriteRecallRules 决定；最下面最多一行字：刚做完的事 > 撤销 > 为什么点不了
/// （提示只显示一小会儿，收掉后剩下的撤销条会自己回来）
struct FavoritesSection: View {
    @ObservedObject var store: FavoriteStore
    let rules: FavoriteRecallRules
    let isGliding: Bool
    /// 未连接时收藏照常能看、能整理；只是滑杆还没出现，文案不再引导"先推滑杆"
    let isConnected: Bool
    let onRecall: (FavoriteSetting) -> Void

    @State private var editing = false
    @State private var notice: String?
    /// 撤销栈：连续删除时每一条都记着（最多 3 条）；撤销条渲染栈顶那条，
    /// 撤销 / 删除各重新计时一次，撤销后剩下的条目还有完整的可撤销时间
    @State private var undoStack: [FavoriteStore.Removed] = []
    /// 刚做完的事（提示）的代次：提示只显示一小会儿，收掉后剩下的撤销条会自己回来
    @State private var noticeGen = 0
    /// 撤销条整组收起的代次（和提示分开计时：显示提示不再清空撤销栈）
    @State private var undoGen = 0
    /// 因为收藏已满没能放回的那条：用户删掉一组腾出位置后，它要排到撤销条最上面，
    /// 下一次"撤销"放回的是它，而不是刚为它腾位置删掉的那组
    @State private var blockedRestore: FavoriteStore.Removed?
    /// 为放回 blockedRestore 而删掉的那几组：放回后收藏又满了，它们再点撤销只会碰上"已满"，直接收起并说一声
    @State private var gaveWay: [FavoriteStore.Removed] = []
    /// 缓推中点亮的是召回的那张（缓推会路过别的收藏的档位，别让高亮中途跳到别人身上）
    @State private var glidingTarget: UUID?
    @FocusState private var focusedName: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 卡片宽度跟着字号放大
    @ScaledMetric(relativeTo: .headline) private var chipWidth: CGFloat = 150
    @ScaledMetric(relativeTo: .headline) private var addWidth: CGFloat = 112

    private var mode: BCProtocol.Mode { rules.mode }

    private var hasOutputToSave: Bool {
        guard mode != .skill else { return false }
        let clamped: [Int] = FavoriteSetting.clamp(rules.levels, maxLevel: mode.maxLevel)
        return clamped.contains { $0 > 0 }
    }

    private var canSave: Bool { hasOutputToSave && !store.isFull && !editing && !isGliding }

    /// 缓推中高亮召回的那张（缓推结束后滑杆正好就是它的档位，无缝衔接）；
    /// 缓推被取消时按实际滑杆值重新算
    private var activeID: UUID? {
        if isGliding { return glidingTarget }
        return store.match(mode: mode, levels: rules.levels)?.id
    }

    /// 撤销条显示栈顶（最近删除的那条）
    private var undo: FavoriteStore.Removed? { undoStack.last }

    /// 加号卡片上的小字：能收藏时说收什么，不能时说为什么（未连接时滑杆还没出现，不说"先推滑杆"）
    private var saveCaption: String {
        if store.isFull { return "已满 \(FavoriteSetting.maxCount) 组" }
        if !isConnected { return "连上设备后可收藏" }
        if isGliding { return "缓推完成后再收藏" }
        // 冷却 / 锁存等暂时不许输出时滑杆是灰的：不叫人去推一根推不动的滑杆
        if !hasOutputToSave { return rules.canOutput ? "先推滑杆" : "安全限制解除后再收藏" }
        return "存下这一刻"
    }

    private var saveHint: String {
        if store.isFull { return "最多收藏 \(FavoriteSetting.maxCount) 组，先整理掉不常用的" }
        if !isConnected { return "先连接设备，调出喜欢的手感再收藏" }
        if isGliding { return "等强度缓缓推到目标后，再收藏" }
        if !hasOutputToSave {
            if rules.canOutput { return "先把滑杆推到喜欢的位置，再收藏" }
            return rules.blockReason ?? "暂时不能输出，安全限制解除后再收藏"
        }
        return "收藏后点一下就回来：强度会缓缓推上去"
    }

    /// 收不了时旁白也要听到原因（提示可能被用户关掉，原因放在值里）
    private var saveA11yValue: String { canSave ? "" : saveCaption }

    /// 撤销条停留多久：旁白用户要先找到"撤销"键，给得宽一些
    private var undoSeconds: Double {
        UIAccessibility.isVoiceOverRunning ? 15 : 6
    }
    /// 提示（footnote 那行字）显示的时长；提示会顶掉撤销条，跟着提示重计的撤销窗口要把这段时间让出去
    private static let noticeSeconds: Double = 2.5

    private var listAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)
    }

    private var editAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if editing && !store.items.isEmpty {
                editList
            } else if store.items.isEmpty {
                emptyCard
            } else {
                tileRow
            }
            footnote
        }
        .animation(listAnimation, value: store.items.map { $0.id })
        .animation(editAnimation, value: editing)
        // 整理到一半切走：名字照样收好（不留空名字）
        .onDisappear { endEditing() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            SectionLabel(title: "我的收藏", systemImage: "heart.fill")
            if !store.items.isEmpty {
                Text("\(store.items.count)/\(FavoriteSetting.maxCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Velvet.textMuted)
                    .accessibilityLabel("已收藏 \(store.items.count) 组，最多 \(FavoriteSetting.maxCount) 组")
            }
            Spacer()
            if !store.items.isEmpty {
                Button {
                    toggleEditing()
                } label: {
                    Text(editing ? "完成" : "整理")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Velvet.gold)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(editing ? "结束整理" : "重命名或删除收藏")
            }
        }
    }

    /// 一排收藏卡片，行尾是「收藏此刻」；新收藏的那张会滚到眼前
    private var tileRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(store.items) { fav in
                        let usable: Bool = rules.usable(fav)
                        let active: Bool = activeID == fav.id
                        let hint: String = rules.hint(for: fav)
                        FavoriteTile(fav: fav, active: active, hint: hint) {
                            glidingTarget = fav.id
                            onRecall(fav)
                            Haptics.light()
                        }
                        .frame(width: chipWidth)
                        .disabled(!usable)
                        .id(fav.id)
                    }
                    // 技能模式不能收藏：不摆一个永远灰着的加号
                    if mode != .skill {
                        addTile
                            .frame(width: addWidth)
                    }
                }
                // 卡片等高（名字两行的那张不会把别的比下去）；给选中卡片的光晕留出地方
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
            }
            .onChange(of: store.items.last?.id) { newID in
                guard let id = newID else { return }
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .trailing)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .trailing) }
                }
            }
        }
    }

    private var addTile: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            save()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Velvet.gold)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(Velvet.gold.opacity(0.6), lineWidth: 1))
                Text("收藏此刻")
                    .font(Velvet.display(.subheadline))
                    .foregroundColor(Velvet.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(saveCaption)
                    .font(.caption2)
                    .foregroundColor(Velvet.textSecondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(Color.white.opacity(0.03)))
            .overlay(shape.strokeBorder(Velvet.gold.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(shape)
        }
        .buttonStyle(SoftPressStyle())
        .disabled(!canSave)
        .accessibilityLabel("收藏此刻的手感")
        .accessibilityValue(saveA11yValue)
        .accessibilityHint(saveHint)
    }

    /// 还没有收藏：一张邀请卡片（技能模式下只说明为什么不能收藏）
    @ViewBuilder private var emptyCard: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if mode == .skill {
            Label("技能本身就是一键。切到变频或手动，调出喜欢的感觉再收藏", systemImage: "sparkles")
                .font(.caption)
                .foregroundColor(Velvet.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(Color.white.opacity(0.03)))
                .overlay(shape.strokeBorder(Velvet.stroke, lineWidth: 1))
        } else {
            Button {
                save()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Velvet.roseGradient))
                        .shadow(color: Velvet.rose.opacity(0.45), radius: 8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("收藏此刻的手感")
                            .font(Velvet.display(.headline))
                            .foregroundColor(Velvet.text)
                        // 能收时是承诺；不能收时把原因写在卡片上（和加号卡片一样），别让人点了个没反应的键
                        Text(canSave ? "下次点一下，就缓缓回到这里" : saveCaption)
                            .font(.caption)
                            .foregroundColor(Velvet.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(Velvet.gold)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(shape.fill(Color.white.opacity(0.03)))
                .overlay(shape.strokeBorder(Velvet.gold.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(shape)
            }
            .buttonStyle(SoftPressStyle())
            .disabled(!canSave)
            .accessibilityLabel("收藏此刻的手感")
            .accessibilityValue(saveA11yValue)
            .accessibilityHint(saveHint)
        }
    }

    private var editList: some View {
        VStack(spacing: 10) {
            ForEach(store.items) { fav in
                FavoriteEditTile(fav: fav,
                                 name: nameBinding(fav),
                                 focused: $focusedName,
                                 onCommit: { store.finalizeNames() },
                                 onDelete: { delete(fav) })
            }
        }
    }

    /// 最多一行：刚做完的事 > 撤销 > 为什么点不了 > 空列表时怎么开始
    /// （提示只显示一小会儿，收掉后剩下的撤销条会自己回来）
    @ViewBuilder private var footnote: some View {
        if let n = notice {
            Label(n, systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundColor(Velvet.blush)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else if let u = undo {
            // 等着放回的那条（收藏已满时没放回去）：常驻写明现在该做什么，不自动收走；不想要了点"算了"
            let pending: Bool = u == blockedRestore
            let full: Bool = store.isFull
            let title: String = pending
                ? (full ? "已满：删掉一组，就能放回「\(u.item.name)」" : "空出一格了，放回「\(u.item.name)」")
                : "已删除「\(u.item.name)」"
            let icon: String = pending ? (full ? "tray.full" : "arrow.uturn.backward") : "trash"
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.caption)
                    .foregroundColor(Velvet.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if pending {
                    Button {
                        dismissPending(u)
                    } label: {
                        Text("算了")
                            .font(.footnote)
                            .foregroundColor(Velvet.textSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("不放回\(u.item.name)")
                }
                Button {
                    undoDelete(u)
                } label: {
                    Text("撤销")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Velvet.gold)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("把\(u.item.name)放回收藏")
            }
            .transition(.opacity)
        } else if !editing, !store.items.isEmpty, let status = rules.status(for: store.items) {
            // 说的是"卡片为什么点不了"：还没有收藏时不说（空卡片上已经写了为什么现在收不了，不再重复一遍）。
            // 真被安全规则挡住才用锁；没连上只是还没开始，用连接的图标
            Label(status, systemImage: isConnected ? "lock.fill" : "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundColor(Velvet.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nameBinding(_ fav: FavoriteSetting) -> Binding<String> {
        Binding(get: { store.items.first { $0.id == fav.id }?.name ?? fav.name },
                set: { store.rename(fav.id, to: $0) })
    }

    private func toggleEditing() {
        if editing {
            endEditing()
        } else {
            editing = true
        }
        Haptics.select()
    }

    private func endEditing() {
        let wasEditing = editing
        focusedName = nil
        store.finalizeNames()
        editing = false
        // 整理期间撤销条不收起：整理完再给一段完整的可撤销时间
        if wasEditing, !undoStack.isEmpty { armUndoDismissal() }
    }

    private func delete(_ fav: FavoriteSetting) {
        guard let removed = store.remove(fav.id) else { return }
        Haptics.soft()
        if store.items.isEmpty {
            focusedName = nil
            editing = false
        }
        // 新的撤销条顶掉可能还在显示的提示（提示的定时器一并作废）
        noticeGen += 1
        // 之前因为已满没放回的那条（用户正是为它腾的位置）排回最上面：下一次"撤销"放回它
        let waiting: FavoriteStore.Removed? = blockedRestore.flatMap { b in undoStack.contains(b) ? b : nil }
        if waiting != nil { gaveWay.append(removed) }
        withAnimation(settleAnimation()) {
            notice = nil
            undoStack.append(removed)
            if let b = waiting, let i = undoStack.firstIndex(of: b) {
                undoStack.remove(at: i)
                undoStack.append(b)
            }
            // 撤销条只有一行：栈太深也摆不下，留最近 3 条
            if undoStack.count > 3 { undoStack.removeFirst(undoStack.count - 3) }
        }
        if let b = waiting {
            UIAccessibility.post(notification: .announcement,
                                 argument: "已删除\(removed.item.name)，空出一格了，点撤销就能放回\(b.item.name)")
        } else {
            UIAccessibility.post(notification: .announcement, argument: "已删除\(removed.item.name)，可以撤销")
        }
        armUndoDismissal()
    }

    /// 撤销条整组收起的计时：删除和撤销各重新计一次，
    /// 撤销一条后剩下的条目还有完整的可撤销时间（提示的显示不清空撤销栈）。
    /// delay：跟着提示重新计的窗口把提示顶掉撤销条的那几秒让出去——提示还盖着"撤销"键时窗口不该走。
    /// 整理中、或有一条等着放回时不悄悄收走：整理完成后重新计时；等着放回的那条由用户放回或点"算了"
    private func armUndoDismissal(after delay: Double = 0) {
        undoGen += 1
        let gen = undoGen
        let settle: Animation? = settleAnimation()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + undoSeconds) {
            guard gen == undoGen, !editing else { return }
            let pending: Bool = blockedRestore.map { undoStack.contains($0) } ?? false
            guard !pending else { return }
            withAnimation(settle) { undoStack = [] }
            blockedRestore = nil
            gaveWay = []
        }
    }

    /// 等着放回的那条不要了：只收起它，别的撤销照旧
    private func dismissPending(_ r: FavoriteStore.Removed) {
        withAnimation(settleAnimation()) { undoStack.removeAll { $0 == r } }
        blockedRestore = nil
        gaveWay = []
        Haptics.select()
        UIAccessibility.post(notification: .announcement, argument: "不再放回\(r.item.name)")
        if !undoStack.isEmpty { armUndoDismissal() }
    }

    private func undoDelete(_ r: FavoriteStore.Removed) {
        switch store.restore(r) {
        case .restored:
            // 放回成功才消费这条撤销；还有别的可撤销的：窗口重新计（提示会顶掉撤销条几秒，从提示收走后再算）
            undoStack.removeAll { $0 == r }
            if blockedRestore == r { blockedRestore = nil }
            gaveWay.removeAll { $0 == r }
            // 放回后又满了：为它让位删掉的那几组再点撤销只会碰上"已满"，直接收起，在提示里说一声
            var gave: [FavoriteStore.Removed] = []
            if store.isFull, !gaveWay.isEmpty {
                gave = undoStack.filter { gaveWay.contains($0) }
                undoStack.removeAll { gaveWay.contains($0) }
                gaveWay = []
            }
            if !undoStack.isEmpty { armUndoDismissal(after: Self.noticeSeconds) }
            Haptics.select()
            if gave.isEmpty {
                flash("已放回「\(r.item.name)」")
            } else {
                let names: String = gave.map { "「\($0.item.name)」" }.joined(separator: "、")
                flash("已放回「\(r.item.name)」，\(names)为它让出了位置")
            }
        case .duplicate:
            // 同样的手感已经在收藏里（满不满都一样）：这条撤销没有意义了，
            // 别让用户再点进同一个失败，更别叫人为它删掉一组
            undoStack.removeAll { $0 == r }
            if blockedRestore == r {
                blockedRestore = nil
                gaveWay = []
            }
            if !undoStack.isEmpty { armUndoDismissal(after: Self.noticeSeconds) }
            Haptics.warning()
            flash("同样的手感已经在收藏里了")
        case .full:
            // 满了放不回去：撤销条留着，记下这条，并常驻写明"删掉一组就能放回"（不自动收走）。
            // 用户删掉一组腾出位置时，delete() 把它排回撤销条最上面，下一次"撤销"放回的就是它
            blockedRestore = r
            armUndoDismissal(after: Self.noticeSeconds)
            Haptics.warning()
            flash("收藏已满 \(FavoriteSetting.maxCount) 组：删掉一组空出位置，再点撤销就能放回「\(r.item.name)」")
        }
    }

    private func save() {
        guard canSave else { return }
        switch store.add(mode: mode, levels: rules.levels) {
        case .added(let fav):
            Haptics.success()
            rearmUndoAroundNotice()
            flash("已收藏「\(fav.name)」，点一下就回来")
        case .duplicate(let fav):
            Haptics.select()
            rearmUndoAroundNotice()
            flash("这组已经在收藏里了：「\(fav.name)」")
        case .full, .invalid:
            break
        }
    }

    /// 收藏成功的提示也会顶掉撤销条：跟着提示重新计的撤销窗口把这几秒让出去（同 undoDelete），
    /// 不然提示盖着"撤销"键时窗口照走，提示收掉后剩下的时间可能不够点，甚至整个窗口在提示底下走完
    private func rearmUndoAroundNotice() {
        if !undoStack.isEmpty { armUndoDismissal(after: Self.noticeSeconds) }
    }

    private func flash(_ text: String) {
        noticeGen += 1
        let gen = noticeGen
        let settle: Animation? = settleAnimation()
        withAnimation(settle) {
            notice = text
        }
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeSeconds) {
            guard gen == noticeGen else { return }
            withAnimation(settle) { notice = nil }
        }
    }

    /// 动画在调度的当下就定好（不在延迟闭包里读环境值）
    private func settleAnimation() -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
}

/// 收藏区的按下效果：不能点时只淡一点（0.55），卡片上的说明字还看得清
private struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftPressBody(configuration: configuration)
    }

    private struct SoftPressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressedScale: CGFloat = (configuration.isPressed && !reduceMotion) ? 0.97 : 1
            configuration.label
                .opacity(isEnabled ? 1 : 0.55)
                .scaleEffect(pressedScale)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// 一组收藏：名字、模式、三个通道的小柱和数值
private struct FavoriteTile: View {
    let fav: FavoriteSetting
    let active: Bool
    let hint: String
    let action: () -> Void

    private var levels: [Int] { fav.clampedLevels ?? [0, 0, 0, 0] }
    private var maxLevel: Int { fav.mode?.maxLevel ?? BCProtocol.maxManualLevel }

    private var a11yLabel: String {
        let parts = BCProtocol.Channel.uiChannels.map { "\($0.displayName) \(levels[$0.rawValue])" }
        return "\(fav.name)，\(fav.mode?.title ?? "")，" + parts.joined(separator: "，")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    // 名字最多 12 个字：两行放得下，不截成"…"
                    Text(fav.name)
                        .font(Velvet.display(.headline))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(fav.mode?.title ?? "")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(active ? Color.white : Velvet.gold)
                }
                Spacer(minLength: 0)
                FavoriteBars(levels: levels, maxLevel: maxLevel, active: active)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tileBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0.3 : 0.09), lineWidth: 1)
            )
            .shadow(color: active ? Velvet.rose.opacity(0.4) : .clear, radius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(a11yLabel)
        .accessibilityHint(hint)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var tileBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if active {
            shape.fill(Velvet.roseGradient)
        } else {
            shape.fill(Velvet.cardFill)
        }
    }
}

private struct FavoriteBars: View {
    let levels: [Int]
    let maxLevel: Int
    let active: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(BCProtocol.Channel.uiChannels, id: \.rawValue) { ch in
                let v: Int = levels[ch.rawValue]
                let frac: CGFloat = maxLevel > 0 ? CGFloat(v) / CGFloat(maxLevel) : 0
                let barHeight: CGFloat = 4 + frac * 18
                RoundedRectangle(cornerRadius: 2)
                    .fill(active ? Color.white : Velvet.channel(ch))
                    .frame(width: 6, height: barHeight)
            }
            Spacer(minLength: 4)
            Text(BCProtocol.Channel.uiChannels.map { String(levels[$0.rawValue]) }.joined(separator: " "))
                .font(.caption.monospacedDigit())
                .foregroundColor(active ? Color.white.opacity(0.9) : Velvet.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        // 最小高度放得下最高的柱子；字放大时跟着长高，不裁字
        .frame(minHeight: 22, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// 整理中的卡片：名字可改、可删除；不能召回
private struct FavoriteEditTile: View {
    let fav: FavoriteSetting
    @Binding var name: String
    var focused: FocusState<UUID?>.Binding
    let onCommit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let count: Int = name.count
        let tooLong: Bool = count > FavoriteSetting.maxNameLength
        let counterColor: Color = tooLong ? Velvet.warning : Velvet.textMuted
        let limit: Int = FavoriteSetting.maxNameLength
        let counterText: String = tooLong ? "\(count)/\(limit)，完成时只保留前 \(limit) 个字" : "\(count)/\(limit)"
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("名字", text: $name)
                    .font(Velvet.display(.headline))
                    .foregroundColor(Velvet.text)
                    .submitLabel(.done)
                    .focused(focused, equals: fav.id)
                    .onSubmit { onCommit() }
                    .frame(minHeight: 44)
                    .accessibilityLabel("收藏名字")
                    .accessibilityHint("最多 \(FavoriteSetting.maxNameLength) 个字")
                HStack(spacing: 8) {
                    Text(fav.mode?.title ?? "")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Velvet.gold)
                    // 打字时不截断（拼音输入不被打断）：超出时先提醒，完成时再截
                    Text(counterText)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(counterColor)
                        .accessibilityHidden(!tooLong)
                }
            }
            Button(role: .destructive, action: onDelete) {
                // 和撤销条上的同一个操作用同一个图标（trash）：一眼认得出是删除
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundColor(Velvet.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除\(fav.name)")
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Velvet.gold.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}
