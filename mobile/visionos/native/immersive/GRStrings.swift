//  Text the window shows, in the reader's language.
//
//  English is the development language and the fallback: a key with no German
//  entry falls back to en.lproj, and a key in neither falls back to itself, so
//  a missing translation degrades to English rather than to a raw identifier.
//
//  SwiftUI localises a `Text("literal")` on its own -- the literal IS the key.
//  Two shapes need help and get it here:
//
//    * a title assembled from values ("Party 4/6"), because those are built as
//      Strings before they reach Text, and a String is not a key
//    * a label whose text arrives at runtime (a tab name, a settings choice
//      that came over the bridge from Lua), because the key is not known when
//      the view is compiled
//
//  Data is deliberately NOT translated: "Lv9", "HP 25/27", "x7", "#3" read the
//  same in every language and a translation would only be a chance to get them
//  wrong.

import Foundation
import SwiftUI

/// A localised, formatted string. Same arguments as String(format:), so
/// ordering can be moved in a translation with %1$@ / %2$lld.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    if args.isEmpty { return format }
    return String(format: format, locale: .current, arguments: args)
}

/// For a key only known at runtime.
func trKey(_ key: String) -> LocalizedStringKey { LocalizedStringKey(key) }
