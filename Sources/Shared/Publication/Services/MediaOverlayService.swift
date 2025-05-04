//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//


// MediaOverlayService.swift
import Foundation
import ReadiumShared

/// Provides access to parsed Media Overlay data (SMIL) for a publication.
public protocol MediaOverlayService: PublicationService {
    /// Retrieves the MediaOverlays object associated with a given XHTML content document's HREF.
    /// - Parameter href: The publication-relative HREF of the XHTML content document.
    /// - Returns: A `MediaOverlays` object if found, otherwise `nil`.
    func mediaOverlays(forLinkHREF href: String) -> MediaOverlays?
}

// Optional: Convenience extension on Publication to easily access the service
public extension Publication {
    /// Access to the Media Overlay data, if available.
    var mediaOverlays: MediaOverlayService? { findService(MediaOverlayService.self) }
}
