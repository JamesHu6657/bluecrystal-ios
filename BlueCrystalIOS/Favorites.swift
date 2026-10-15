import SwiftUI
import UIKit

// MARK: - 我的收藏：记住喜欢的变频 / 手动强度，下次一点就缓缓回到那里。
// 只存 UserDefaults 里的几组数字；召回交给 ManualControlVM.applyFavorite，走手动页同一条发送路径，
// 不新增任何发帧方式，也不碰准入 / 额度 / 看门狗。存取时都按各模式范围夹紧（FavoriteSetting.clamp）。
// 收藏区不弹任何 alert / sheet：重命名是卡片里的输入框、删除可撤销，底部停止键始终在键盘上面可点。
// 界面只有一块：滑杆下面的「我的收藏」——一排卡片点了就回去，行尾「收藏此刻」，「整理」就地重命名 / 删除。

final class FavoriteStore: ObservableObject {
    static let storageKey = "bc.ui.favorites.v1"
    /// 第四轮：启动时有记录读不出来，就把当时的原始数据另存在这里（之后的保存只写 storageKey，不会把它盖掉）
    static let backupKey = "bc.ui.favorites.v1.unreadableBackup"

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
        /// 第四轮：删除那一刻全部收藏的顺序（含它自己）。连续删几组再任意顺序撤销，也按原顺序放回
        var order: [UUID] = []
    }

    init() {
        let defaults = UserDefaults.standard
        let raw = defaults.data(forKey: Self.storageKey)
        // 第四轮：逐条解码，一条坏记录不再把全部收藏清空；读不出来的那部分连同原始数据先另存一份
        let decoded = FavoriteCodec.decodeReport(raw)
        items = decoded.items
        if decoded.unreadable > 0, let r = raw {
            defaults.set(r, forKey: Self.backupKey)
        }
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
        let removed = Removed(item: items[i], index: i, order: items.map { $0.id })
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

    /// 撤销删除：放回原位；已经在了 / 同样的手感又收藏过一次、或满了就不放。
    /// 第四轮：位置按删除时的顺序快照算（FavoriteRestore），连续删除后以任意顺序撤销都回到原来的顺序
    @discardableResult
    func restore(_ r: Removed) -> RestoreResult {
        if items.contains(where: { $0.id == r.item.id || $0.sameSetting(as: r.item) }) { return .duplicate }
        guard !isFull else { return .full }
        let at: Int = FavoriteRestore.insertionIndex(of: r.item.id, order: r.order,
                                                     current: items.map { $0.id }, fallback: r.index)
        items.insert(r.item, at: min(max(0, at), items.count))
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

    /// 第四轮：编码失败时不写——UserDefaults.set(nil, forKey:) 会把已存的收藏整个删掉，保留上一次成功写入的版本
    private func persist() {
        guard let data = FavoriteCodec.encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - 我的收藏（滑杆下面）：一排卡片 + 行尾「收藏此刻」，整理就地展开

/// 手感页唯一的收藏区：点卡片召回、点行尾的加号卡片收藏此刻、「整理」就地重命名 / 删除（可撤销）。
/// 卡片能不能点由 FavoriteRecallRules 决定；最下面一行字（为等空位的那条整理时挪到列表上面）：
/// 刚做完的事 > 等空位的那条 > 撤销 > 为什么点不了
/// （提示只显示一小会儿，收掉后剩下的撤销条会自己回来；等空位的那条常驻，下面照常写为什么点不了）
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
    /// 等空位的那条：收藏满着时在撤销条上点了「去整理」（要它回来），移出撤销栈单独放着，
    /// 撤销条优先显示它、常驻不自动收走，放回或点"算了"才收。等它的时候再删的几组照常进撤销栈
    @State private var waiting: FavoriteStore.Removed?
    /// 这次整理是为等空位的那条来的：撤销条放在整理列表上面（跟着「完成」），删掉一组马上看得见「撤销」。
    /// 整理开始时定下、整理中不挪（行的位置不因为撤销条换地方而跳）
    @State private var barAboveList = false
    /// 缓推中点亮的是召回的那张（缓推会路过别的收藏的档位，别让高亮中途跳到别人身上）
    @State private var glidingTarget: UUID?
    @FocusState private var focusedName: UUID?
    /// 点「去整理」后旁白焦点落到第一行的删除键（点过的键已经不在了，焦点不能悬空）
    @AccessibilityFocusState private var deleteFocus: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        // 额度 / 锁存等暂时不许输出时滑杆是灰的：不叫人去推一根推不动的滑杆
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
        let footnoteOnTop: Bool = editing && barAboveList && !store.items.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            header
            if footnoteOnTop {
                footnote
            }
            if editing && !store.items.isEmpty {
                editList
            } else if store.items.isEmpty {
                emptyCard
            } else {
                tileRow
            }
            if !footnoteOnTop {
                footnote
            }
        }
        .animation(listAnimation, value: store.items.map { $0.id })
        .animation(editAnimation, value: editing)
        .onChange(of: store.items.map { $0.id }) { _ in reconcileUndo() }
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
                                 deleteFocus: $deleteFocus,
                                 onCommit: { store.finalizeNames() },
                                 onDelete: { delete(fav) })
            }
        }
    }

    /// 刚做完的事 > 等着放回的那条（常驻，下面照常写卡片为什么点不了）> 撤销 > 为什么点不了
    /// （提示只显示一小会儿，收掉后撤销条会自己回来）
    @ViewBuilder private var footnote: some View {
        if let n = notice {
            Label(n, systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundColor(Velvet.blush)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else if let w = waiting {
            // 常驻、不自动收走，所以不能把"为什么点不了"那行一直挤掉：两行都留
            VStack(alignment: .leading, spacing: 2) {
                undoBar(w, isWaiting: true)
                statusLine
            }
            .transition(.opacity)
        } else if let u = undo {
            undoBar(u, isWaiting: false)
                .transition(.opacity)
        } else {
            statusLine
        }
    }

    /// 撤销条（等空位的那条和撤销栈顶共用一种写法）。收藏满着时一律不给「撤销」（点了只会碰上"已满"）：
    /// 写"删掉一组就能放回"并给「去整理」（整理中删除键就在眼前，不再给）；有空位才给「撤销」。
    /// 等空位的那条多一个「算了」。大字号时说明在上、按键在下一行，说明不被挤成一窄条
    private func undoBar(_ r: FavoriteStore.Removed, isWaiting: Bool) -> some View {
        let full: Bool = store.isFull
        let name: String = r.item.name
        let title: String
        let icon: String
        if full {
            title = "已满：删掉一组，就能放回「\(name)」"
            icon = "tray.full"
        } else if isWaiting {
            title = "空出一格了，放回「\(name)」"
            icon = "arrow.uturn.backward"
        } else {
            title = "已删除「\(name)」"
            icon = "trash"
        }
        let label = Label(title, systemImage: icon)
            .font(.caption)
            .foregroundColor(Velvet.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        let actions = HStack(spacing: 8) {
            if isWaiting {
                Button {
                    dismissWaiting(r)
                } label: {
                    Text("算了")
                        .font(.footnote)
                        .foregroundColor(Velvet.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("不放回\(name)")
            }
            if !full {
                barAction("撤销", hint: "把\(name)放回收藏") { undoDelete(r) }
            } else if !editing {
                barAction("去整理", hint: "删掉一组，给\(name)空出位置") { makeRoom(for: r) }
            }
        }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    label
                    actions
                }
            } else {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 4)
                    actions
                }
            }
        }
    }

    /// 撤销条上的金色动作键
    private func barAction(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(Velvet.gold)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    /// 卡片为什么点不了：还没有收藏时不说（空卡片上已经写了为什么现在收不了，不再重复一遍）。
    /// 真被安全规则挡住才用锁；没连上只是还没开始，用连接的图标
    @ViewBuilder private var statusLine: some View {
        if !editing, !store.items.isEmpty, let status = rules.status(for: store.items) {
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
        } else if store.isFull, waiting == nil, let u = undo {
            // 满着、撤销条上那条（"已满：删掉一组，就能放回"）还没等空位时点了标题的「整理」：
            // 和撤销条上的「去整理」走同一条路，让它改为等空位（常驻、撤销条放到列表上面）。
            // 不然删掉一组后它被压在新删的那组下面，撤销新删的那组又占满位置，consumeUndo 清栈时它就丢了。
            // makeRoom 会再回到这里开始整理（那时已经有等空位的那条，不会再进这个分支）；震动在那一次里给
            makeRoom(for: u)
            return
        } else {
            barAboveList = waiting != nil
            editing = true
        }
        Haptics.select()
    }

    private func endEditing() {
        let wasEditing = editing
        focusedName = nil
        store.finalizeNames()
        editing = false
        barAboveList = false
        // 整理期间撤销条不收起：整理完再给一段完整的可撤销时间
        if wasEditing, !undoStack.isEmpty { armUndoDismissal() }
    }

    /// 满着时点「去整理」（或满着、栈顶还有一条时点标题的「整理」，见 toggleEditing）：
    /// 这条改为等空位（常驻，删掉一组后先给它「撤销」），栈里别的几组满着放不回、一并收起
    private func makeRoom(for r: FavoriteStore.Removed) {
        withAnimation(settleAnimation()) {
            undoStack = []
            waiting = r
        }
        if !editing { toggleEditing() }
        if UIAccessibility.isVoiceOverRunning {
            // 等整理列表出来（编辑动画 0.2 秒）再挪焦点
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard editing else { return }
                deleteFocus = store.items.first?.id
            }
        }
    }

    private func delete(_ fav: FavoriteSetting) {
        guard let removed = store.remove(fav.id) else { return }
        Haptics.soft()
        if store.items.isEmpty {
            focusedName = nil
            editing = false
            barAboveList = false
        }
        // 新的撤销条顶掉可能还在显示的提示（提示的定时器一并作废）
        noticeGen += 1
        withAnimation(settleAnimation()) {
            notice = nil
            undoStack.append(removed)
            // 撤销条只有一行：栈太深也摆不下，留最近 3 条
            if undoStack.count > 3 { undoStack.removeFirst(undoStack.count - 3) }
        }
        // 有一条在等空位时撤销条先给它（用户正是为它腾的位置）；刚删的这组放回它之后照常可撤销
        if let w = waiting {
            UIAccessibility.post(notification: .announcement,
                                 argument: "已删除\(removed.item.name)，空出一格了，点撤销就能放回\(w.item.name)")
        } else {
            UIAccessibility.post(notification: .announcement, argument: "已删除\(removed.item.name)，可以撤销")
        }
        armUndoDismissal()
    }

    /// 撤销条整组收起的计时：删除和撤销各重新计一次，
    /// 撤销一条后剩下的条目还有完整的可撤销时间（提示的显示不清空撤销栈）。
    /// delay：跟着提示重新计的窗口把提示顶掉撤销条的那几秒让出去——提示还盖着"撤销"键时窗口不该走。
    /// 整理中、或有一条等着放回时不悄悄收走：整理完成 / 等的那条有了结果后重新计时
    /// （等的时候再删的几组藏在它后面，不能在看不见时把它们的撤销收走）
    private func armUndoDismissal(after delay: Double = 0) {
        undoGen += 1
        let gen = undoGen
        let settle: Animation? = settleAnimation()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + undoSeconds) {
            guard gen == undoGen, !editing, waiting == nil else { return }
            withAnimation(settle) { undoStack = [] }
        }
    }

    /// 等着放回的那条不要了：只收起它；等的时候删掉的几组照常可撤销
    private func dismissWaiting(_ w: FavoriteStore.Removed) {
        withAnimation(settleAnimation()) { waiting = nil }
        Haptics.select()
        UIAccessibility.post(notification: .announcement, argument: "不再放回\(w.item.name)")
        if !undoStack.isEmpty { armUndoDismissal() }
    }

    /// 这条（或同样的手感）已经在收藏里了：放不回，撤销只会碰上"已在"
    private func alreadyStored(_ r: FavoriteStore.Removed) -> Bool {
        store.items.contains { $0.id == r.item.id || $0.sameSetting(as: r.item) }
    }

    /// 收藏变了就把点了只会失败的撤销收掉（一处规则，删除、收藏、放回都走这里）：
    /// - 同样的手感已经又在收藏里：等空位的那条收起并说一声（别让人白删一组），栈里的悄悄去掉；
    /// - 收藏满了：有等空位的那条时栈里的全收起（藏在它后面，满着也放不回）；
    ///   没有时只留最近删的一条，撤销条把它写成"已满"并给「去整理」，不给撤销
    private func reconcileUndo() {
        var droppedWaiting: FavoriteStore.Removed?
        if let w = waiting, alreadyStored(w) {
            waiting = nil
            droppedWaiting = w
        }
        var stack: [FavoriteStore.Removed] = undoStack.filter { !alreadyStored($0) }
        if store.isFull { stack = waiting == nil ? Array(stack.suffix(1)) : [] }
        if stack != undoStack {
            withAnimation(settleAnimation()) { undoStack = stack }
        }
        if let w = droppedWaiting {
            if !undoStack.isEmpty { armUndoDismissal(after: Self.noticeSeconds) }
            flash("同样的手感已经在收藏里了，「\(w.item.name)」不用再放回")
        }
    }

    /// 一个模型：撤销栈（定时收起）+ 最多一条等空位的（常驻）；满着时撤销条不给撤销（见 undoBar / reconcileUndo）。
    /// 放回成功 / 同样的手感已在：这条撤销用掉了
    private func undoDelete(_ r: FavoriteStore.Removed) {
        switch store.restore(r) {
        case .restored:
            consumeUndo(r)
            Haptics.select()
            flash("已放回「\(r.item.name)」")
        case .duplicate:
            consumeUndo(r)
            Haptics.warning()
            flash("同样的手感已经在收藏里了")
        case .full:
            // 撤销键只在有空位时出现，到不了这里；万一到了，和「去整理」前一样改为等空位
            withAnimation(settleAnimation()) {
                undoStack = []
                waiting = r
            }
            Haptics.warning()
            flash("收藏已满 \(FavoriteSetting.maxCount) 组：删掉一组，就能放回「\(r.item.name)」")
        }
    }

    /// 用掉一条撤销（等空位的那条或栈里的）。放回后满了：剩下的几组用的正是刚占掉的那一格，
    /// 点了只会碰上"已满"，一并收起；还有空位：窗口重新计（提示会顶掉撤销条几秒，从提示收走后再算）
    private func consumeUndo(_ r: FavoriteStore.Removed) {
        if waiting == r { waiting = nil }
        undoStack.removeAll { $0 == r }
        if store.isFull { undoStack = [] }
        if !undoStack.isEmpty { armUndoDismissal(after: Self.noticeSeconds) }
    }

    private func save() {
        guard canSave else { return }
        switch store.add(mode: mode, levels: rules.levels) {
        case .added(let fav):
            Haptics.success()
            if let w = waiting, w.item.sameSetting(as: fav) {
                // 存下的正是等着放回的手感：一句话说完两件事（不然收藏的提示马上被"不用再放回"顶掉）
                withAnimation(settleAnimation()) { waiting = nil }
                rearmUndoAroundNotice()
                flash("已收藏「\(fav.name)」；「\(w.item.name)」不用再放回了")
            } else {
                rearmUndoAroundNotice()
                flash("已收藏「\(fav.name)」，点一下就回来")
            }
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
    var deleteFocus: AccessibilityFocusState<UUID?>.Binding
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
            .accessibilityFocused(deleteFocus, equals: fav.id)
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
