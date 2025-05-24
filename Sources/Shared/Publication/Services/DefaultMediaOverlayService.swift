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
        // First, try a direct match
        if let foundOverlay = overlaysByXHTMLHREF[href] {
            return foundOverlay
        }

        // If direct match fails, try appending ".smil"
        let smilHref = href + ".smil"
        if let foundOverlayWithSmil = overlaysByXHTMLHREF[smilHref] {
            return foundOverlayWithSmil
        }
        
        // If both attempts fail, log and return nil
        log(.info, "Couldn't find media overlays for '\(href)' or '\(smilHref)'.")
        
        // For more detailed debugging, you can uncomment this:
        // logger.debug("Available keys in overlaysByXHTMLHREF: \(self.overlaysByXHTMLHREF.keys.joined(separator: ", "))")
        
        return nil
    }
}
