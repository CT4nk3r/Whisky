//
//  UnityPointerShim.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import CryptoKit
import Foundation
import os.log

/// Installs the externally-maintained WM_POINTER compatibility proxy only for
/// Unity games whose own Player.log proves that Wine's pointer stubs broke input.
///
/// The proxy is deliberately not bundled: it comes from a pinned upstream revision
/// and its SHA-256 is verified before it is copied next to a game executable.
enum UnityPointerShim {
    private static let log = Logger(
        subsystem: Bundle.whiskyBundleIdentifier, category: "unity-pointer-shim"
    )
    private static let fingerprint = "EnableMouseInPointer failed"
    private static let marker = "WINE_PTRSHIM_MARKER_V1"
    private static let shimURL = URL(string:
        "https://raw.githubusercontent.com/feiyuehchen/Meccha-Chameleon-For-MAC/"
            + "2bf0c1779f0982280d04774e9ea675e7f33df783/ptrshim/version.dll"
    ) ?? URL(fileURLWithPath: "/")
    private static let shimSHA256 = "7b4b719501eb99bb907711776021bbbdc7e7003ca732bbad10a5840bde17e878"

    /// Installs the shim beside `executable` when the Unity title was previously
    /// observed to fail the pointer API. Failure is intentionally non-fatal: a
    /// network or filesystem error must never prevent a game from launching.
    static func prepare(for executable: URL, in bottle: Bottle) async -> Bool {
        guard let gameDirectory = gameDirectory(for: executable) else {
            return false
        }
        return await prepare(in: gameDirectory, bottle: bottle)
    }

    /// Steam starts the game as a descendant of steam.exe, so its launch path
    /// knows the install directory rather than the final executable.
    static func prepare(in gameDirectory: URL, bottle: Bottle) async -> Bool {
        guard needsShim(in: gameDirectory, bottle: bottle) else { return false }
        if hasInstalledShim(in: gameDirectory) { return true }

        let destination = gameDirectory.appending(path: "version.dll")
        // A game or mod owns this proxy. Do not replace it merely because the
        // game also has the Unity pointer failure fingerprint.
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }

        do {
            let (data, response) = try await URLSession.shared.data(from: shimURL)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                log.error("Unity pointer shim download returned an unexpected response")
                return false
            }
            let checksum = SHA256.hash(data: data)
                .compactMap { String(format: "%02x", $0) }
                .joined()
            guard checksum == shimSHA256 else {
                log.error("Unity pointer shim checksum mismatch")
                return false
            }
            try install(data, in: gameDirectory)
            return true
        } catch {
            log.error("Unable to install Unity pointer shim: \(error.localizedDescription)")
            return false
        }
    }

    static func gameDirectory(for executable: URL) -> URL? {
        let directory = executable.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: directory.appending(path: "UnityPlayer.dll").path)
            ? directory
            : nil
    }

    static func needsShim(in gameDirectory: URL, bottle: Bottle) -> Bool {
        guard let logURL = playerLogURL(in: gameDirectory, bottle: bottle),
              let contents = try? String(contentsOf: logURL, encoding: .utf8)
        else { return false }
        return contents.contains(fingerprint)
    }

    static func hasInstalledShim(in gameDirectory: URL) -> Bool {
        guard let contents = try? Data(contentsOf: gameDirectory.appending(path: "version.dll")) else {
            return false
        }
        return contents.range(of: Data(marker.utf8)) != nil
    }

    static func playerLogURL(in gameDirectory: URL, bottle: Bottle) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: gameDirectory, includingPropertiesForKeys: nil
        )
        guard let dataDirectory = contents?.first(where: { $0.lastPathComponent.hasSuffix("_Data") }),
              let info = try? String(contentsOf: dataDirectory.appending(path: "app.info"), encoding: .utf8)
        else { return nil }
        let names = info.split(whereSeparator: \.isNewline).map(String.init)
        guard names.count >= 2, !names[0].isEmpty, !names[1].isEmpty else { return nil }

        let users = bottle.url.appending(path: "drive_c/users")
        guard let homes = try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)
        else {
            return nil
        }
        return homes.lazy.map {
            $0.appending(path: "AppData/LocalLow/\(names[0])/\(names[1])/Player.log")
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func addingVersionOverride(to programOverrides: ProgramOverrides?) -> ProgramOverrides {
        var result = programOverrides ?? ProgramOverrides()
        var overrides = result.dllOverrides ?? []
        overrides.removeAll { $0.dllName.caseInsensitiveCompare("version") == .orderedSame }
        overrides.append(DLLOverrideEntry(dllName: "version", mode: .nativeThenBuiltin))
        result.dllOverrides = overrides
        return result
    }

    private static func install(_ data: Data, in gameDirectory: URL) throws {
        let destination = gameDirectory.appending(path: "version.dll")
        let temporary = gameDirectory.appending(path: ".whisky-ptrshim-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
