import SwiftUI

private enum SectionInsertionRelation {
    case before
    case after
}

private struct SectionChoice: Identifiable {
    let id: UUID
    let title: String
}

struct ContentView: View {
    @Bindable var state: PresentationState
    @State private var selection: UUID?
    @State private var isDeckEditing = false
    @State private var collapsedSectionIDs: Set<UUID> = []

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Slides")
                        .font(.headline)
                    Spacer()
                    if !collapsedSectionIDs.isEmpty {
                        Button {
                            expandAllSections()
                        } label: {
                            Image(systemName: "arrow.up.and.down.text.horizontal")
                        }
                        .buttonStyle(.plain)
                        .help("Expand all sections")
                    }
                    Button {
                        isDeckEditing.toggle()
                    } label: {
                        Image(systemName: isDeckEditing ? "pencil.circle.fill" : "pencil.circle")
                    }
                    .buttonStyle(.plain)
                    .help(isDeckEditing ? "Exit edit mode" : "Enter edit mode")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                List(selection: $selection) {
                    ForEach(state.deck.sections) { section in
                        let isCollapsed = collapsedSectionIDs.contains(section.id)
                        SectionAnchorRow(
                            title: sectionTitleBinding(for: section.id),
                            itemCount: section.items.count,
                            isCollapsed: isCollapsed,
                            isEditing: isDeckEditing,
                            canDelete: state.deck.sections.count > 1,
                            canMoveUp: canMoveSection(section.id, step: -1),
                            canMoveDown: canMoveSection(section.id, step: 1),
                            onDelete: { deleteSection(section.id) },
                            onMoveUp: { moveSectionByStep(section.id, step: -1) },
                            onMoveDown: { moveSectionByStep(section.id, step: 1) },
                            onToggleCollapsed: { toggleSectionCollapse(section.id) }
                        )
                        .id("section-anchor-\(section.id.uuidString)")

                        if !isCollapsed {
                            ForEach(section.items) { item in
                                DeckItemRow(
                                    item: item,
                                    isEditing: isDeckEditing,
                                    currentSectionID: section.id,
                                    sectionChoices: sectionChoices(),
                                    canMoveUp: canMoveItem(item.id, step: -1),
                                    canMoveDown: canMoveItem(item.id, step: 1),
                                    onItemChange: {
                                        state.markDirtyAndSave()
                                    },
                                    onURLCommit: {
                                        state.markDirtyAndSave()
                                        state.triggerCacheWarmup()
                                    },
                                    onMoveUp: {
                                        moveItemByStep(item.id, step: -1)
                                    },
                                    onMoveDown: {
                                        moveItemByStep(item.id, step: 1)
                                    },
                                    onMoveToSection: { targetSectionID in
                                        moveItemToSection(item.id, targetSectionID: targetSectionID)
                                    },
                                    onDeleteItem: {
                                        deleteItem(id: item.id)
                                    }
                                )
                                    .tag(item.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, newValue in
                    state.setCurrentItem(id: newValue)
                }
                .onChange(of: state.currentItemID) { _, newValue in
                    if selection != newValue {
                        selection = newValue
                    }
                }
                .onChange(of: state.deck.sections.map(\.id)) { _, _ in
                    syncCollapsedSectionIDs()
                }

                HStack {
                    Menu {
                        Button("Add Web Slide") {
                            addItem(.web(url: "https://example.com"))
                        }
                        Button("Add Text Slide") {
                            addItem(.text(heading: "New Heading", markdown: ""))
                        }
                        Button("Add Tweet Slide") {
                            addItem(.tweet(url: "https://x.com/"))
                        }
                        Button("Add YouTube Slide") {
                            addItem(.youtube(url: "https://www.youtube.com/watch?v=", fallbackLocalPath: nil))
                        }
                        Divider()
                        Button("Add Section") {
                            addSection()
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!isDeckEditing)

                    Button(action: deleteSelected) {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil || !isDeckEditing)

                    Menu {
                        ForEach(state.deck.sections) { section in
                            Button {
                                moveSelectedItemToSection(section.id)
                            } label: {
                                if selectedSectionID() == section.id {
                                    Label(displaySectionTitle(section.title), systemImage: "checkmark")
                                } else {
                                    Text(displaySectionTitle(section.title))
                                }
                            }
                            .disabled(selection == nil || selectedSectionID() == section.id)
                        }
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right.circle")
                    }
                    .help("Move selected slide to section")
                    .disabled(selection == nil || !isDeckEditing)

                    Button {
                        YouTubeLoginWindowController.shared.open()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    .help("Sign in to YouTube")

                    Spacer()
                }
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 320, max: 520)
        } detail: {
            if let item = state.currentPresentableItem {
                WebView(
                    item: item,
                    pageZoom: state.zoomLevel,
                    deckBaseURL: state.deckFolderURL,
                    bookmarks: state.bookmarks,
                    screenshotStore: state.screenshotStore
                )
            } else {
                VStack {
                    Text("No slide selected")
                        .foregroundStyle(.secondary)
                    Text("Add a section and slide to get started")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            state.ensureNonEmptyDeck()
            selection = state.currentPresentableItem?.id
            state.triggerCacheWarmup()
        }
    }

    private func sectionTitleBinding(for sectionID: UUID) -> Binding<String> {
        Binding(
            get: {
                state.deck.sections.first(where: { $0.id == sectionID })?.title ?? ""
            },
            set: { newValue in
                guard let index = state.deck.sections.firstIndex(where: { $0.id == sectionID }) else { return }
                state.deck.sections[index].title = newValue
                state.markDirtyAndSave()
            }
        )
    }

    private func selectedSectionID() -> UUID? {
        guard let selection else {
            return state.deck.sections.first?.id
        }
        for section in state.deck.sections where section.items.contains(where: { $0.id == selection }) {
            return section.id
        }
        return state.deck.sections.first?.id
    }

    private func displaySectionTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Section" : trimmed
    }

    private func sectionChoices() -> [SectionChoice] {
        state.deck.sections.map { section in
            SectionChoice(id: section.id, title: displaySectionTitle(section.title))
        }
    }

    private func addSection() {
        let section = DeckSection(title: "New Section")
        state.deck.sections.append(section)
        state.markDirtyAndSave()
    }

    private func addItem(_ kind: DeckItemKind) {
        guard let sectionID = selectedSectionID(),
              let sectionIndex = state.deck.sections.firstIndex(where: { $0.id == sectionID }) else {
            return
        }

        let item = DeckItem(kind: kind)
        state.deck.sections[sectionIndex].items.append(item)
        selection = item.id
        state.setCurrentItem(id: item.id)
        state.markDirtyAndSave()
        state.triggerCacheWarmup()
    }

    private func deleteItems(in sectionID: UUID, offsets: IndexSet) {
        guard let sectionIndex = state.deck.sections.firstIndex(where: { $0.id == sectionID }) else { return }

        let removedIDs = offsets.compactMap { offset in
            state.deck.sections[sectionIndex].items.indices.contains(offset)
                ? state.deck.sections[sectionIndex].items[offset].id
                : nil
        }

        state.deck.sections[sectionIndex].items.remove(atOffsets: offsets)

        if let currentID = selection, removedIDs.contains(currentID) {
            selection = state.presentableItems.first?.id
            state.setCurrentItem(id: selection)
        }

        state.ensureNonEmptyDeck()
        state.markDirtyAndSave()
    }

    private func deleteSection(_ sectionID: UUID) {
        guard state.deck.sections.count > 1,
              let sectionIndex = state.deck.sections.firstIndex(where: { $0.id == sectionID }) else {
            return
        }

        let removedIDs = Set(state.deck.sections[sectionIndex].items.map(\.id))
        state.deck.sections.remove(at: sectionIndex)

        if let selected = selection, removedIDs.contains(selected) {
            selection = state.presentableItems.first?.id
            state.setCurrentItem(id: selection)
        }

        collapsedSectionIDs.remove(sectionID)
        state.ensureNonEmptyDeck()
        state.markDirtyAndSave()
    }

    private func deleteSelected() {
        guard let selection else { return }

        for section in state.deck.sections {
            if let itemIndex = section.items.firstIndex(where: { $0.id == selection }) {
                deleteItems(in: section.id, offsets: IndexSet(integer: itemIndex))
                break
            }
        }
    }

    private func deleteItem(id: UUID) {
        for section in state.deck.sections {
            if let itemIndex = section.items.firstIndex(where: { $0.id == id }) {
                deleteItems(in: section.id, offsets: IndexSet(integer: itemIndex))
                return
            }
        }
    }

    private func findItemLocation(id: UUID) -> (sectionIndex: Int, itemIndex: Int)? {
        for sectionIndex in state.deck.sections.indices {
            if let itemIndex = state.deck.sections[sectionIndex].items.firstIndex(where: { $0.id == id }) {
                return (sectionIndex, itemIndex)
            }
        }
        return nil
    }

    private func canMoveSection(_ sectionID: UUID, step: Int) -> Bool {
        guard let index = state.deck.sections.firstIndex(where: { $0.id == sectionID }) else {
            return false
        }
        let target = index + step
        return target >= 0 && target < state.deck.sections.count
    }

    private func moveSectionByStep(_ sectionID: UUID, step: Int) {
        guard isDeckEditing else { return }
        guard let index = state.deck.sections.firstIndex(where: { $0.id == sectionID }) else {
            return
        }

        let target = index + step
        guard target >= 0 && target < state.deck.sections.count else {
            return
        }

        let targetID = state.deck.sections[target].id
        let relation: SectionInsertionRelation = step < 0 ? .before : .after
        _ = moveSection(
            draggedSectionID: sectionID,
            relativeTo: targetID,
            relation: relation
        )
    }

    private func canMoveItem(_ itemID: UUID, step: Int) -> Bool {
        guard let source = findItemLocation(id: itemID) else {
            return false
        }
        let target = source.itemIndex + step
        return target >= 0 && target < state.deck.sections[source.sectionIndex].items.count
    }

    private func moveItemByStep(_ itemID: UUID, step: Int) {
        guard isDeckEditing else { return }
        guard let source = findItemLocation(id: itemID) else {
            return
        }

        let targetIndex = source.itemIndex + step
        guard targetIndex >= 0 && targetIndex < state.deck.sections[source.sectionIndex].items.count else {
            return
        }

        let toOffset = step > 0 ? targetIndex + 1 : targetIndex
        state.deck.sections[source.sectionIndex].items.move(
            fromOffsets: IndexSet(integer: source.itemIndex),
            toOffset: toOffset
        )
        selection = itemID
        state.setCurrentItem(id: itemID)
        state.markDirtyAndSave()
    }

    private func moveSelectedItemToSection(_ targetSectionID: UUID) {
        guard isDeckEditing, let selectedID = selection else {
            return
        }
        moveItemToSection(selectedID, targetSectionID: targetSectionID)
    }

    private func toggleSectionCollapse(_ sectionID: UUID) {
        var updatedCollapsedSectionIDs = collapsedSectionIDs
        if updatedCollapsedSectionIDs.contains(sectionID) {
            updatedCollapsedSectionIDs.remove(sectionID)
        } else {
            updatedCollapsedSectionIDs.insert(sectionID)
        }

        // If current selection becomes hidden by collapsing, move selection to
        // a visible row to avoid keyboard actions being applied to hidden items.
        if updatedCollapsedSectionIDs.contains(sectionID),
           let selectedID = selection,
           sectionIDForItem(selectedID) == sectionID {
            let fallbackSelection = firstVisibleItemID(using: updatedCollapsedSectionIDs)
            selection = fallbackSelection
            state.setCurrentItem(id: fallbackSelection)
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            collapsedSectionIDs = updatedCollapsedSectionIDs
        }
    }

    private func expandAllSections() {
        withAnimation(.easeInOut(duration: 0.18)) {
            collapsedSectionIDs.removeAll()
        }
    }

    private func syncCollapsedSectionIDs() {
        let knownSectionIDs = Set(state.deck.sections.map(\.id))
        collapsedSectionIDs = collapsedSectionIDs.intersection(knownSectionIDs)
    }

    private func sectionIDForItem(_ itemID: UUID) -> UUID? {
        for section in state.deck.sections where section.items.contains(where: { $0.id == itemID }) {
            return section.id
        }
        return nil
    }

    private func firstVisibleItemID(using collapsedIDs: Set<UUID>) -> UUID? {
        for section in state.deck.sections where !collapsedIDs.contains(section.id) {
            if let itemID = section.items.first?.id {
                return itemID
            }
        }
        return state.presentableItems.first?.id
    }

    private func moveItemToSection(_ draggedID: UUID, targetSectionID: UUID) {
        guard isDeckEditing else { return }
        guard let source = findItemLocation(id: draggedID) else {
            return
        }

        let movingItem = state.deck.sections[source.sectionIndex].items[source.itemIndex]
        state.deck.sections[source.sectionIndex].items.remove(at: source.itemIndex)

        guard let destinationSectionIndex = state.deck.sections.firstIndex(where: { $0.id == targetSectionID }) else {
            let rollbackIndex = min(source.itemIndex, state.deck.sections[source.sectionIndex].items.count)
            state.deck.sections[source.sectionIndex].items.insert(movingItem, at: rollbackIndex)
            return
        }

        let destinationIndex = state.deck.sections[destinationSectionIndex].items.count
        state.deck.sections[destinationSectionIndex].items.insert(movingItem, at: destinationIndex)

        selection = movingItem.id
        state.setCurrentItem(id: movingItem.id)
        state.markDirtyAndSave()
    }

    private func moveSection(
        draggedSectionID: UUID,
        relativeTo targetSectionID: UUID,
        relation: SectionInsertionRelation
    ) -> Bool {
        guard let fromIndex = state.deck.sections.firstIndex(where: { $0.id == draggedSectionID }),
              fromIndex < state.deck.sections.count else {
            return false
        }
        guard fromIndex != state.deck.sections.firstIndex(where: { $0.id == targetSectionID }) else {
            return false
        }

        let movingSection = state.deck.sections.remove(at: fromIndex)
        guard let targetIndexAfterRemoval = state.deck.sections.firstIndex(where: { $0.id == targetSectionID }) else {
            state.deck.sections.insert(movingSection, at: min(fromIndex, state.deck.sections.count))
            return false
        }

        let rawInsertionIndex: Int
        switch relation {
        case .before:
            rawInsertionIndex = targetIndexAfterRemoval
        case .after:
            rawInsertionIndex = targetIndexAfterRemoval + 1
        }

        let insertionIndex = min(max(rawInsertionIndex, 0), state.deck.sections.count)
        state.deck.sections.insert(movingSection, at: insertionIndex)
        state.markDirtyAndSave()
        return true
    }
}

private struct SectionAnchorRow: View {
    @Binding var title: String
    let itemCount: Int
    let isCollapsed: Bool
    let isEditing: Bool
    let canDelete: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggleCollapsed: () -> Void

    var body: some View {
        SectionHeaderRow(
            title: $title,
            itemCount: itemCount,
            isCollapsed: isCollapsed,
            isEditing: isEditing,
            canDelete: canDelete,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            onDelete: onDelete,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onToggleCollapsed: onToggleCollapsed
        )
    }
}

private struct SectionHeaderRow: View {
    @Binding var title: String
    let itemCount: Int
    let isCollapsed: Bool
    let isEditing: Bool
    let canDelete: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggleCollapsed: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCollapsed) {
                Image(systemName: isCollapsed ? "chevron.right.circle.fill" : "chevron.down.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand section" : "Collapse section")

            if isEditing {
                TextField("Section", text: $title)
                    .textFieldStyle(.plain)
                    .font(.headline.weight(.semibold))
            } else {
                Text(title)
                    .font(.headline.weight(.semibold))
            }

            Text("\(itemCount) \(itemCount == 1 ? "slide" : "slides")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())

            Spacer()

            if isEditing {
                Button {
                    onMoveUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .help("Move section up")
                .disabled(!canMoveUp)
                .opacity(canMoveUp ? 1 : 0.3)

                Button {
                    onMoveDown()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Move section down")
                .disabled(!canMoveDown)
                .opacity(canMoveDown ? 1 : 0.3)
            }

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete section")
            .opacity(canDelete && isEditing ? 1 : 0.3)
            .disabled(!canDelete || !isEditing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct DeckItemRow: View {
    @Bindable var item: DeckItem
    let isEditing: Bool
    let currentSectionID: UUID
    let sectionChoices: [SectionChoice]
    let canMoveUp: Bool
    let canMoveDown: Bool
    var onItemChange: () -> Void
    var onURLCommit: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onMoveToSection: (UUID) -> Void
    var onDeleteItem: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.sidebarTitle)
                    .lineLimit(1)

                if isEditing, item.sourceURLString != nil {
                    TextField(
                        "URL",
                        text: Binding(
                            get: { item.editableTarget },
                            set: { newValue in
                                item.editableTarget = newValue
                                onItemChange()
                            }
                        ),
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                onURLCommit()
                            }
                        },
                        onCommit: {
                            onURLCommit()
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text(item.sidebarSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isEditing {
                Button {
                    onMoveUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .help("Move slide up")
                .disabled(!canMoveUp)
                .opacity(canMoveUp ? 1 : 0.3)

                Button {
                    onMoveDown()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Move slide down")
                .disabled(!canMoveDown)
                .opacity(canMoveDown ? 1 : 0.3)

                Menu {
                    ForEach(sectionChoices) { section in
                        Button {
                            onMoveToSection(section.id)
                        } label: {
                            if section.id == currentSectionID {
                                Label(section.title, systemImage: "checkmark")
                            } else {
                                Text(section.title)
                            }
                        }
                        .disabled(section.id == currentSectionID)
                    }
                } label: {
                    Image(systemName: "arrowshape.turn.up.right.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Move slide to section")

                Button {
                    onDeleteItem()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete slide")
            }
        }
        .padding(.vertical, 2)
    }
}
