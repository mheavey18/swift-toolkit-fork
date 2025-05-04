//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//


// DefaultMediaOverlayService.swift
import Foundation

extension DefaultMediaOverlayService: Loggable {}

public class DefaultMediaOverlayService: MediaOverlayService {
    private let overlaysByXHTMLHREF: [String: MediaOverlays]

    public init(overlaysByXHTMLHREF: [String: MediaOverlays]) {
        self.overlaysByXHTMLHREF = overlaysByXHTMLHREF
        log(.info, "DefaultMediaOverlayService initialized with \(overlaysByXHTMLHREF.count) overlay entries.")
    }

    public func mediaOverlays(forLinkHREF href: String) -> MediaOverlays? {
        let found = overlaysByXHTMLHREF[href]
        if found == nil {
            // It's common for HREFs to have slight variations (e.g., leading slash).
            // You might want to add normalization logic here if keys aren't matching.
            // For example, trying to match with and without a leading "/".
            // For now, direct match:
            // Log.debug(message: "MediaOverlayService: No overlays found for \(href). Available keys: \(overlaysByXHTMLHREF.keys)")
        }
        return found
    }
}
