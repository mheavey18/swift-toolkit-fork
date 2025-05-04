//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumFuzi
import ReadiumShared

/// Epub related constants.
private enum EPUBConstant {
    /// Media Overlays URL.
    static let mediaOverlayURL = "media-overlay?resource="
}

/// Errors thrown during the parsing of the EPUB
///
/// - wrongMimeType: The mimetype file is missing or its content differs from
///                 "application/epub+zip" (expected).
/// - missingFile: A file is missing from the container at `path`.
/// - xmlParse: An XML parsing error occurred.
/// - missingElement: An XML element is missing.
public enum EPUBParserError: Error {
    /// The mimetype of the EPUB is not valid.
    case wrongMimeType
    case missingFile(path: String)
    case xmlParse(underlyingError: Error)
    /// Missing rootfile in `container.xml`.
    case missingRootfile
}

extension EPUBParser: Loggable {}

/// An EPUB container parser that extracts the information from the relevant
/// files and builds a `Publication` instance out of it.
public final class EPUBParser: PublicationParser {
    private let reflowablePositionsStrategy: EPUBPositionsService.ReflowableStrategy

    public init(reflowablePositionsStrategy: EPUBPositionsService.ReflowableStrategy = .recommended) {
        self.reflowablePositionsStrategy = reflowablePositionsStrategy
    }

    public func parse(
        asset: Asset,
        warnings: WarningLogger?
    ) async -> Result<Publication.Builder, PublicationParseError> {
        guard
            asset.format.conformsTo(.epub),
            case let .container(assetContainer) = asset // Renamed for clarity from your code
        else {
            return .failure(.formatNotSupported)
        }

        do {
            let container = assetContainer.container // Get the actual Container
            let opfHREF = try await EPUBContainerParser(container: container).parseOPFHREF()
            let encryptions = await (try? EPUBEncryptionParser(container: container))?.parseEncryptions() ?? [:]

            let opfComponents = try await OPFParser(container: container, opfHREF: opfHREF, encryptions: encryptions).parsePublication()
            let metadata = opfComponents.metadata
            // Create the initial manifest with all links for reference during SMIL parsing
            let initialManifest = Manifest(
                metadata: metadata,
                readingOrder: opfComponents.readingOrder,
                resources: opfComponents.resources
                // subcollections will be added later
            )

            let deobfuscator = EPUBDeobfuscator(publicationId: metadata.identifier ?? "", encryptions: encryptions)

            // *** 1. Parse Media Overlays First to get the data ***
            var parsedOverlays: [String: MediaOverlays] = [:]
            do {
                // Call your existing parseMediaOverlay function, but it should RETURN the dictionary
                // or be an internal helper that populates `parsedOverlays`.
                // For simplicity, let's assume it's structured to return the dictionary.
                // You'll need to pass `initialManifest` to it.
                parsedOverlays = try await parseMediaOverlayDataInternal( // Renamed to avoid conflict with your existing one
                    from: container,
                    manifest: initialManifest // Pass the manifest created from OPF components
                )
            } catch {
                log(.error, "Failed during media at parsing step: \(error)")
                // Decide if this error should be fatal or just a warning
            }

            // *** 2. Prepare the ServicesBuilder ***
            var servicesBuilder = PublicationServicesBuilder(
                content: DefaultContentService.makeFactory(
                    resourceContentIteratorFactories: [HTMLResourceContentIterator.Factory()]
                ),
                positions: EPUBPositionsService.makeFactory(reflowableStrategy: reflowablePositionsStrategy),
                search: StringSearchService.makeFactory()
                // Add other default EPUB services if necessary
            )

            // *** 3. Conditionally add MediaOverlayService to the builder ***
            if !parsedOverlays.isEmpty {
                servicesBuilder.set(MediaOverlayService.self) { _ in // context can be ignored
                    DefaultMediaOverlayService(overlaysByXHTMLHREF: parsedOverlays)
                }
                log(.info, "MediaOverlayService registered with \(parsedOverlays.count) entries.")
            } else {
                log(.info, "No media overlays found or parsed, MediaOverlayService not registered.")
            }

            // *** 4. Parse Collections (Nav Doc, NCX) ***
            // Note: parseCollections now needs the combined links, not just the initial manifest.
            // The Manifest inside Publication.Builder will be the one including links from services.
            // This means subcollections might be better parsed *after* the Publication.Builder is more complete
            // or the Manifest object is finalized.
            // For now, let's assume the subcollections are based on the OPF links.
            let opfLinks = opfComponents.readingOrder + opfComponents.resources
            let subcollections = await parseCollections(in: container, links: opfLinks)

            // *** 5. Construct and return the Publication.Builder ***
            return .success(Publication.Builder(
                manifest: Manifest( // Re-create manifest with subcollections
                    metadata: metadata,
                    readingOrder: opfComponents.readingOrder,
                    resources: opfComponents.resources,
                    subcollections: subcollections
                ),
                container: container.map { url, resource in
                    deobfuscator.deobfuscate(resource: resource, at: url)
                },
                servicesBuilder: servicesBuilder // Pass the configured servicesBuilder
            ))

        } catch {
            return .failure(.reading(.decoding(error)))
        }
    }

    private func parseCollections(in container: Container, links: [Link]) async -> [String: [PublicationCollection]] {
            var collections = await parseNavigationDocument(in: container, links: links)
            if collections["toc"]?.first?.links.isEmpty != false {
                // Falls back on the NCX tables.
                await collections.merge(parseNCXDocument(in: container, links: links), uniquingKeysWith: { first, _ in first })
            }
            return collections
        }

        // MARK: - Internal Methods.

        /// Attempt to fill the `Publication`'s `tableOfContent`, `landmarks`, `pageList` and `listOfX` links collections using the navigation document.
        private func parseNavigationDocument(in container: Container, links: [Link]) async -> [String: [PublicationCollection]] {
            // Get the link in the readingOrder pointing to the Navigation Document.
            guard
                let navLink = links.firstWithRel(.contents),
                let navURI = RelativeURL(string: navLink.href),
                let navDocumentData = try? await container.readData(at: navURI)
            else {
                return [:]
            }

            // Get the location of the navigation document in order to normalize href paths.
            let navigationDocument = NavigationDocumentParser(data: navDocumentData, at: navURI)

            var collections: [String: [PublicationCollection]] = [:]
            func addCollection(_ type: NavigationDocumentParser.NavType, role: String) {
                let links = navigationDocument.links(for: type)
                if !links.isEmpty {
                    collections[role] = [PublicationCollection(links: links)]
                }
            }

            addCollection(.tableOfContents, role: "toc")
            addCollection(.pageList, role: "pageList")
            addCollection(.landmarks, role: "landmarks")
            addCollection(.listOfAudiofiles, role: "loa")
            addCollection(.listOfIllustrations, role: "loi")
            addCollection(.listOfTables, role: "lot")
            addCollection(.listOfVideos, role: "lov")

            return collections
        }

        /// Attempt to fill `Publication.tableOfContent`/`.pageList` using the NCX
        /// document. Will only modify the Publication if it has not be filled
        /// previously (using the Navigation Document).
        private func parseNCXDocument(in container: Container, links: [Link]) async -> [String: [PublicationCollection]] {
            // Get the link in the readingOrder pointing to the NCX document.
            guard
                let ncxLink = links.firstWithMediaType(.ncx),
                let ncxURI = RelativeURL(string: ncxLink.href),
                let ncxDocumentData = try? await container.readData(at: ncxURI)
            else {
                return [:]
            }

            let ncx = NCXParser(data: ncxDocumentData, at: ncxURI)

            var collections: [String: [PublicationCollection]] = [:]
            func addCollection(_ type: NCXParser.NavType, role: String) {
                let links = ncx.links(for: type)
                if !links.isEmpty {
                    collections[role] = [PublicationCollection(links: links)]
                }
            }

            addCollection(.tableOfContents, role: "toc")
            addCollection(.pageList, role: "pageList")

            return collections
        }
    
    
    // Your existing parseMediaOverlay function, slightly adapted to be an internal helper
    // that *returns* the dictionary.
    private func parseMediaOverlayDataInternal(
        from container: Container,
        manifest: Manifest
    ) async throws -> [String: MediaOverlays] {

        var allParsedMediaOverlays: [String: MediaOverlays] = [:]

        for xhtmlLink in manifest.links { // Iterate all links to find those with media-overlay-id
            // 1. Get the XHTML Href (which is the key for your dictionary)
            //    and the ID of the SMIL file.
            //    `xhtmlLink.href` is already a String.
            let xhtmlHref = xhtmlLink.href
            guard let smilItemID = xhtmlLink.properties["media-overlay-id"] as? String else {
                continue // This link doesn't have a media overlay associated.
            }

            // 2. Find the Link object for the SMIL file in the manifest by its ID.
            guard let smilLink = manifest.links.first(where: { ($0.properties["id"] as? String) == smilItemID }) else {
                // Use self.log because this is an instance method of EPUBParser
                self.log(.warning, "SMIL file with ID '\(smilItemID)' referenced by \(xhtmlHref) not found in manifest.")
                continue
            }

            // 3. Get the SMIL file's URL (as AnyURL) and then its string representation for logging/errors.
            //    The `container` subscript expects an `AnyURL`. `smilLink.url()` provides this.
            let smilAnyURL = smilLink.url() // This is AnyURL

            guard let smilResource = container[smilAnyURL], // Pass AnyURL here
                  let smilData = try? await smilResource.read().get()
            else {
                self.log(.warning, "Could not read SMIL file content for: \(smilAnyURL.string)") // Use smilAnyURL.string
                continue
            }
            
            // 4. Prepare baseHREF for SMILParser (which expects RelativeURL?)
            //    smilLink.href is a String representing a relative path within the EPUB.
            //    So, it can be used to initialize a RelativeURL.
            let smilBaseHREF = RelativeURL(string: smilLink.href) // Initialize RelativeURL from the href string

            // 5. Parse the SMIL data
            switch SMILParser.parse(smilData: smilData, baseHREF: smilBaseHREF) {
            case .success(let parsedSMIL):
                allParsedMediaOverlays[xhtmlHref] = parsedSMIL // Key with xhtmlLink.href (String)
                self.log(.info, "Successfully parsed SMIL for \(xhtmlHref)")
            case .failure(let error):
                self.log(.error, "Failed to parse SMIL file \(smilAnyURL.string): \(error)")
            }
        }
        return allParsedMediaOverlays
    }
}

