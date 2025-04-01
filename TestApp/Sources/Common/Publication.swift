//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreServices
import Foundation
import ReadiumShared

extension Publication {
    /// Finds all the downloadable links for this publication.
    var downloadLinks: [Link] {
        links.filter {
            ($0.mediaType.map { DocumentTypes.main.supportsMediaType($0.string) } == true)
                || DocumentTypes.main.supportsFileExtension($0.url().pathExtension?.rawValue)
        }
    }
    
    /// A computed property to check if the publication contains
    /// potentially playable audio resources.
    var containsSignificantAudio: Bool {
       // Check both the main reading order and linked resources.
       // You might refine this logic based on your specific needs,
       // e.g., looking for specific link 'rel' values or minimum counts.
       let hasAudioInReadingOrder = readingOrder.contains { link in
           link.mediaType?.isAudio ?? false
       }

       let hasAudioInResources = resources.contains { link in
           link.mediaType?.isAudio ?? false
       }

       return hasAudioInReadingOrder || hasAudioInResources
    }
}
