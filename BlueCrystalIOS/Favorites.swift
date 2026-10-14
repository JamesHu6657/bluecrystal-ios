import SwiftUI
import UIKit

// MARK: - 我的收藏：记住喜欢的变频 / 手动强度，下次一点就缓缓回到那里。
// 只存 UserDefaults 里的几组数字；召回交给 ManualControlVM.applyFavorite，走手动页同一条发送路径，
// 不新增任何发帧方式，也不碰准入 / 冷却 / 额度 / 看门狗。存取时都按各模式范围夹紧（FavoriteSetting.clamp）。
// 收藏区不弹任何 alert / sheet：重命名是卡片里的输入框、删除可撤销，底部停止键始终在键盘上面可点。

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

    /// 撤销删除：放回原位；满了或已经在了就不放
    @discardableResult
    func restore(_ r: Removed) -> Bool {
        guard !isFull, !items.contains(where: { $0.id == r.item.id }) else { return false }
        let at: Int = min(max(0, r.index), items.count)
        items.insert(r.item, at: at)
        persist()
        return true
    }

    /// 打字过程中：只去掉换行、限制长度（不去首尾空格，否则空格打不出来）
    func rename(_ id: UUID, to raw: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let flat = raw.components(separatedBy: .newlines).joined()
        let capped = String(flat.prefix(FavoriteSetting.maxNameLength))
        guard capped != items[i].name else { return }
        items[i].name = capped
        persist()
    }

    /// 整理完成：空名字补上自动名，去掉首尾空白
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

/// 手感页的收藏区：收藏此刻、一键召回、整理（重命名 / 删除 / 撤销删除）
struct FavoritesPanel: View {
    @ObservedObject var store: FavoriteStore
    let mode: BCProtocol.Mode
    let levels: [Int]
    let canOutput: Bool
    /// 现在不能召回的原因（未连接 / 冷却 / 额度 / 锁存）；canOutput 为 true 时为 nil
    let blockReason: String?
    /// 正在输出（本次运行还开着）。这时召回别的模式的收藏要先停机、停机后还要冷却，
    /// 点下去只会停下并报冷却，所以这些收藏先锁住并说明（同模式的照常一点就到）
    let running: Bool
    let onRecall: (FavoriteSetting) -> Void

    @State private var editing = false
    @State private var notice: String?
    @State private var undo: FavoriteStore.Removed?
    @State private var noticeGen = 0
    @FocusState private var focusedName: UUID?

    private var activeID: UUID? { store.match(mode: mode, levels: levels)?.id }

    private var hasOutputToSave: Bool {
        mode != .skill && FavoriteSetting.clamp(levels, maxLevel: mode.maxLevel).contains { $0 > 0 }
    }

    /// 收藏键下面的一句说明（不能收藏时说清楚为什么）
    private var saveHint: String {
        if mode == .skill { return "技能本身就是一键；切到变频或手动，调出喜欢的感觉再收藏" }
        if store.isFull { return "最多收藏 \(FavoriteSetting.maxCount) 组，先整理掉不常用的" }
        if !hasOutputToSave { return "先把滑杆推到喜欢的位置，再收藏" }
        return "收藏后一点就回来：强度会在一秒内缓缓推上去"
    }

    /// 空列表时上面已经有一句引导，和"先把滑杆推上去"重复，就不再说一遍
    private var showsSaveHint: Bool {
        mode == .skill || !store.items.isEmpty || hasOutputToSave
    }

    private func crossModeLocked(_ fav: FavoriteSetting) -> Bool {
        running && fav.mode != mode
    }

    /// 召回卡片的一句状态（不能点时说为什么）
    private var recallStatus: String? {
        if let r = blockReason { return r }
        if running && store.items.contains(where: { $0.mode != mode }) {
            return "正在输出：其他模式的收藏要先停止，冷却结束后再点"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !store.items.isEmpty {
                grid
                if !editing, let status = recallStatus {
                    Label(status, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(Velvet.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if mode != .skill {
                Text("调到最喜欢的那一下，收藏起来，下次一点就回到那里。")
                    .font(.caption)
                    .foregroundColor(Velvet.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 技能模式下收藏键永远不能用，不摆一个灰按钮，只留一句说明
            if mode != .skill {
                saveButton
            }
            footnote
        }
        .velvetCard()
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.items.map { $0.id })
        .animation(.easeInOut(duration: 0.2), value: editing)
        // 整理到一半切走：名字照样收好（不留空名字）
        .onDisappear { endEditing() }
    }

    private var header: some View {
        HStack {
            SectionLabel(title: "我的收藏", systemImage: "heart")
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

    private var grid: some View {
        // 整理时一行一张：输入框和删除键都要够宽
        let two: [GridItem] = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        let one: [GridItem] = [GridItem(.flexible())]
        let columns: [GridItem] = editing ? one : two
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(store.items) { fav in
                if editing {
                    FavoriteEditTile(fav: fav,
                                     name: nameBinding(fav),
                                     focused: $focusedName,
                                     onCommit: { store.finalizeNames() },
                                     onDelete: { delete(fav) })
                } else {
                    let locked: Bool = crossModeLocked(fav)
                    let usable: Bool = canOutput && fav.clampedLevels != nil && !locked
                    FavoriteTile(fav: fav, active: activeID == fav.id, hint: tileHint(locked: locked)) {
                        onRecall(fav)
                        Haptics.light()
                    }
                    .disabled(!usable)
                }
            }
        }
    }

    private func tileHint(locked: Bool) -> String {
        if let r = blockReason { return r }
        if locked { return "正在输出，切换模式要先停止并冷却" }
        return "缓缓推到这组强度"
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Label("收藏此刻的手感", systemImage: "heart.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .disabled(editing || !hasOutputToSave || store.isFull)
        .accessibilityHint(saveHint)
    }

    @ViewBuilder private var footnote: some View {
        if let u = undo {
            HStack(spacing: 8) {
                Label("已删除「\(u.item.name)」", systemImage: "trash")
                    .font(.caption)
                    .foregroundColor(Velvet.textSecondary)
                Spacer(minLength: 4)
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
        } else if let n = notice {
            Label(n, systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundColor(Velvet.blush)
                .transition(.opacity)
        } else if showsSaveHint {
            Text(saveHint)
                .font(.caption)
                .foregroundColor(Velvet.textMuted)
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
        focusedName = nil
        store.finalizeNames()
        editing = false
    }

    private func delete(_ fav: FavoriteSetting) {
        guard let removed = store.remove(fav.id) else { return }
        Haptics.soft()
        if store.items.isEmpty {
            focusedName = nil
            editing = false
        }
        noticeGen += 1
        let gen = noticeGen
        withAnimation {
            notice = nil
            undo = removed
        }
        UIAccessibility.post(notification: .announcement, argument: "已删除\(removed.item.name)，可以撤销")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard gen == noticeGen else { return }
            withAnimation { undo = nil }
        }
    }

    private func undoDelete(_ r: FavoriteStore.Removed) {
        let ok = store.restore(r)
        undo = nil
        if ok {
            Haptics.select()
            flash("已放回「\(r.item.name)」")
        }
    }

    private func save() {
        switch store.add(mode: mode, levels: levels) {
        case .added(let fav):
            Haptics.success()
            flash("已收藏「\(fav.name)」")
        case .duplicate(let fav):
            Haptics.select()
            flash("这组已经在收藏里了：「\(fav.name)」")
        case .full, .invalid:
            break
        }
    }

    private func flash(_ text: String) {
        noticeGen += 1
        let gen = noticeGen
        withAnimation {
            undo = nil
            notice = text
        }
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard gen == noticeGen else { return }
            withAnimation { notice = nil }
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
                    Text(fav.name)
                        .font(Velvet.display(.headline))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(fav.mode?.title ?? "")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(active ? Color.white : Velvet.gold)
                }
                FavoriteBars(levels: levels, maxLevel: maxLevel, active: active)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(tileBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0.3 : 0.09), lineWidth: 1)
            )
            .shadow(color: active ? Velvet.rose.opacity(0.4) : .clear, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
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
        }
        .frame(height: 22, alignment: .bottom)
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
                Text(fav.mode?.title ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Velvet.gold)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
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
