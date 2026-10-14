import AppKit
import FoxlumeQueryCore

/// The Presets pull-down of the filter bar: apply a saved set of filters, save the current one, delete one.
/// Presets belong to one table and live in `filter-presets.json` in the data folder.
extension FilterBarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === presetButton.menu else { return }
        menu.removeAllItems()
        // A pull-down button shows its first item as the title.
        menu.addItem(NSMenuItem(title: "Presets", action: nil, keyEquivalent: ""))
        guard let presets else { return }
        let saved = presets.store.presets(for: presets.scope)
        for preset in saved {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPresetFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            let missing = preset.missingColumns(in: presetColumns)
            if !missing.isEmpty {
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Some columns are missing")
                item.toolTip = "This table has no column " + missing.map { "“\($0)”" }.joined(separator: ", ")
            }
            menu.addItem(item)
        }
        if !saved.isEmpty { menu.addItem(.separator()) }
        let save = NSMenuItem(title: "Save Filters as Preset…", action: #selector(savePresetFromMenu(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if !saved.isEmpty {
            let delete = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for preset in saved {
                let item = NSMenuItem(title: preset.name, action: #selector(deletePresetFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset
                submenu.addItem(item)
            }
            delete.submenu = submenu
            menu.addItem(delete)
        }
    }

    @objc private func applyPresetFromMenu(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? FilterPreset else { return }
        applyPreset(preset)
    }

    /// Puts the preset's rules, raw condition and logic in the bar and applies them.
    func applyPreset(_ preset: FilterPreset) {
        let rules = preset.rules.map { rule -> FilterRule in
            var copy = rule
            copy.id = UUID()
            return copy
        }
        load(rules: rules, rawWhere: preset.rawWhere, logic: preset.logic)
        applyNow()
    }

    @objc private func savePresetFromMenu(_ sender: Any?) {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        let alert = NSAlert()
        alert.messageText = "Save Filter Preset"
        alert.informativeText = "Saves the filters shown in the bar for this table."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.savePreset(named: field.stringValue)
        }
    }

    /// Saves what the bar shows now. A name the table already uses gets a number, as in TablePro.
    @discardableResult
    func savePreset(named name: String) -> FilterPreset? {
        guard let presets else { return nil }
        do {
            return try presets.store.save(name: name, rules: rules, logic: logic, rawWhere: rawWhereText, for: presets.scope)
        } catch {
            Alerts.showError(error, title: "The preset was not saved", in: window)
            return nil
        }
    }

    @objc private func deletePresetFromMenu(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? FilterPreset else { return }
        deletePreset(preset)
    }

    func deletePreset(_ preset: FilterPreset) {
        guard let presets else { return }
        do {
            try presets.store.delete(id: preset.id, for: presets.scope)
        } catch {
            Alerts.showError(error, title: "The preset was not deleted", in: window)
        }
    }
}
