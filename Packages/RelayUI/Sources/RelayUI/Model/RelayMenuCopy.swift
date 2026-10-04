// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Native app commands use the same localized vocabulary as the in-app controls.
/// Resolving here keeps the app shell independent of the package resource bundle.
public enum RelayMenuCopy {
    public static var importGames: String { L("Import…") }
    public static var game: String { L("Game") }
    public static var resume: String { L("Resume") }
    public static var pause: String { L("Pause") }
    public static var quickSave: String { L("Quick Save") }
    public static var quickLoad: String { L("Quick Load") }
    public static var saveNow: String { L("Save Now") }
    public static var loadSave: String { L("Load Save…") }
    public static var fastForward: String { L("Fast Forward") }
    public static var normalSpeed: String { L("Normal Speed") }
    public static var exitGame: String { L("Exit Game") }
    public static var supportedFormats: String { L("Which formats work?") }
    public static var diagnostics: String { L("Diagnostics…") }
}
