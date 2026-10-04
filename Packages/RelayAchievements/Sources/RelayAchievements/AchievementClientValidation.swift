// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Release configuration must name the version actually approved by RA and its
/// durable approval reference. User defaults and runtime flags cannot grant it.
/// Isolated local-fixture tests inject validation without contacting RA.
public enum AchievementClientValidation {
    public static var isCurrentVersionApproved: Bool {
        let bundle = Bundle.main
        guard let current = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let approved = bundle.object(forInfoDictionaryKey: "RelayRAApprovedVersion") as? String,
              let reference = bundle.object(forInfoDictionaryKey: "RelayRAApprovalReference") as? String else { return false }
        return !current.isEmpty && current == approved && !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
