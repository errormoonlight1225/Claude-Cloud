//
//  PackageController+TranslateMenu.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/20.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import LegacyCompat
import UIKit

extension PackageController {
    /// How a package page reads.
    enum TranslationMode: CaseIterable {
        /// As its author wrote it.
        case original
        /// In the target language.
        case translated
        /// As written, with the translation under each piece.
        case compared

        var title: String {
            switch self {
            case .original: String(legacyLocalized: "Original")
            case .translated: String(legacyLocalized: "Translated")
            case .compared: String(legacyLocalized: "Compared")
            }
        }
    }

    /// Translate, in the page's menu under Select Version: how the page
    /// reads, checked, then the two languages, each a list of what the
    /// engine offers. nil on a system with no engine to ask.
    var translateMenu: LegacyMenu? {
        guard SystemTranslator.isPresent else { return nil }
        let modes = TranslationMode.allCases.map { mode in
            LegacyAction(title: mode.title, state: mode == translationMode ? .on : .off) { [weak self] _ in
                self?.translationMode = mode
                self?.showTranslation(asked: true)
            }
        }
        let target = AutomaticTranslation.target
        let source = translationSource
        let targetIdentifier = AutomaticTranslation.targetIdentifier
        let languages = [
            languageMenu(
                title: String(legacyLocalized: "Source Language"),
                chosen: translationSource,
                detects: true,
                list: \.sources
            ) { [weak self] in
                self?.translationSource = $0
            } restore: { [weak self] in
                self?.translationSource = source
            },
            languageMenu(
                title: String(legacyLocalized: "Target Language"),
                chosen: target,
                detects: false,
                list: \.targets
            ) {
                if let locale = $0 {
                    AutomaticTranslation.target = locale
                }
            } restore: {
                AutomaticTranslation.targetIdentifier = targetIdentifier
            },
        ]
        return LegacyMenu(
            title: String(legacyLocalized: "Translate"),
            image: UIImage.compatSystemImage("character.bubble"),
            children: [
                LegacyMenu(options: .displayInline, children: modes),
                LegacyMenu(options: .displayInline, children: languages),
            ]
        )
    }

    /// A language, chosen from what the engine lists when the menu opens.
    /// Choosing one translates the page again when it is showing a
    /// translation; on Original it is kept for when it does. `restore` puts
    /// back what was chosen when the menu opened, for a translation cancelled.
    private func languageMenu(
        title: String,
        chosen: Locale?,
        detects: Bool,
        list: KeyPath<(sources: [Locale], targets: [Locale]), [Locale]>,
        choose: @escaping (Locale?) -> Void,
        restore: @escaping () -> Void
    ) -> LegacyMenu {
        func name(_ locale: Locale) -> String {
            Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        }
        func action(_ locale: Locale?, title: String) -> LegacyAction {
            // the user's own language is "zh-Hans" where the engine lists "zh_CN"
            let isChosen = switch (locale, chosen) {
            case (nil, nil): true
            case let (locale?, chosen?):
                if #available(iOS 16, *) {
                    Locale.Language(identifier: locale.identifier)
                        .isEquivalent(to: Locale.Language(identifier: chosen.identifier))
                } else {
                    Locale.IdentifierParts(locale.identifier)
                        .isEquivalent(to: Locale.IdentifierParts(chosen.identifier))
                }
            default: false
            }
            return LegacyAction(title: title, state: isChosen ? .on : .off) { [weak self] _ in
                choose(locale)
                guard let self, translationMode != .original else { return }
                showTranslation(asked: true, onCancel: restore)
            }
        }
        let options = LegacyDeferredMenuElement.uncached { completion in
            LegacyTask.detached {
                let locales = SystemTranslator.languages()?[keyPath: list] ?? []
                completion(
                    locales
                        .map { (locale: $0, name: name($0)) }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        .map { action($0.locale, title: $0.name) }
                )
            }
        }
        var children: [LegacyMenuElement] = [options]
        if detects {
            children.insert(
                LegacyMenu(options: .displayInline, children: [action(nil, title: String(legacyLocalized: "Detect Language"))]),
                at: 0
            )
        }
        let menu = LegacyMenu(title: title, children: children)
        menu.subtitle = chosen.map(name) ?? String(legacyLocalized: "Detect Language")
        return menu
    }
}
