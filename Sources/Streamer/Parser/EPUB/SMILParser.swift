// SMILParser.swift
import Foundation
import ReadiumFuzi
import ReadiumShared

class SMILParser: Loggable {

    /// Parses the given SMIL data into a `MediaOverlays` object.
    /// - Parameters:
    ///   - smilData: The raw Data of the SMIL file.
    ///   - baseHREF: The HREF of the SMIL file itself, used to resolve relative paths
    ///               within the SMIL (e.g., for audio src and text src).
    /// - Returns: A `Result` containing the `MediaOverlays` object or an `Error`.
    static func parse(smilData: Data, baseHREF: RelativeURL?) -> Result<MediaOverlays, Error> {
        do {
            let document = try XMLDocument(data: smilData)
            // Define namespaces used in SMIL.
            // The default namespace is often "http://www.w3.org/ns/SMIL".
            // EPUB-specific attributes like epub:type use "http://www.idpf.org/2007/ops".
            document.definePrefix("smil", forNamespace: "http://www.w3.org/ns/SMIL")
            document.definePrefix("epub", forNamespace: "http://www.idpf.org/2007/ops")

            let mediaOverlays = MediaOverlays() // The main container for all nodes in this SMIL file

            // SMIL body is the typical starting point.
            // It might contain <seq> (sequence) or <par> (parallel) elements directly.
            // A common structure is body > seq > par.
            // This example directly looks for <par> elements. A more robust parser
            // would recursively handle <seq> elements.

            // We'll use a recursive helper for parsing sequences and parallels
            if let bodyElement = document.xpath("//smil:body").first {
                parseChildren(of: bodyElement, parentNode: nil, mediaOverlays: mediaOverlays, baseHREF: baseHREF)
            } else if let rootElement = document.root { // Fallback if no explicit body, try parsing from root
                 parseChildren(of: rootElement, parentNode: nil, mediaOverlays: mediaOverlays, baseHREF: baseHREF)
            }


            if mediaOverlays.nodes.isEmpty {
                log(.warning, "SMILParser: No <par> elements found or parsed in \(baseHREF?.string ?? "SMIL file").")
            }

            return .success(mediaOverlays)

        } catch {
            log(.warning, "SMILParser: Error parsing SMIL data for \(baseHREF?.string ?? ""): \(error)")
            return .failure(error)
        }
    }

    /// Recursive helper to parse children of a SMIL element (e.g., body, seq).
    private static func parseChildren(
        of fuziElement: ReadiumFuzi.XMLElement,
        parentNode: MediaOverlayNode?, // Parent MediaOverlayNode in our model, if inside a <seq>
        mediaOverlays: MediaOverlays, // The top-level container to add <par> nodes to
        baseHREF: RelativeURL?
    ) {
        for childElement in fuziElement.children {
            switch childElement.tag {
            case "par":
                if let parNode = parseParElement(childElement, baseHREF: baseHREF) {
                    if let parent = parentNode {
                        parent.children.append(parNode)
                    } else {
                        mediaOverlays.nodes.append(parNode)
                    }
                }
            case "seq":
                let seqNode = MediaOverlayNode() // Create a node for the <seq> itself
                seqNode.role.append("sequence") // Or derive from epub:type
                if let textRef = childElement.attr("textref", namespace: "epub") ?? childElement.attr("epub:textref") {
                     if let textURL = RelativeURL(string: textRef) {
                         seqNode.text = baseHREF?.resolve(textURL)?.string ?? textRef
                    } else {
                        seqNode.text = textRef
                    }
                }
                // Add epub:type to roles
                if let epubType = childElement.attr("type", namespace: "epub") ?? childElement.attr("epub:type") {
                    seqNode.role.append(contentsOf: epubType.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
                }


                if let parent = parentNode {
                    parent.children.append(seqNode)
                } else {
                    mediaOverlays.nodes.append(seqNode)
                }
                // Recursively parse children of this <seq>
                parseChildren(of: childElement, parentNode: seqNode, mediaOverlays: mediaOverlays, baseHREF: baseHREF)

            default:
                // Ignore other elements or log them
                break
            }
        }
    }

    /// Parses a <par> Fuzi element into a `MediaOverlayNode`.
    private static func parseParElement(_ parElement: ReadiumFuzi.XMLElement, baseHREF: RelativeURL?) -> MediaOverlayNode? {
            guard let textElement = parElement.firstChild(xpath: "smil:text"),
                  let textSrcWithFragment = textElement.attr("src"),
                  let audioElement = parElement.firstChild(xpath: "smil:audio"),
                  let audioSrc = audioElement.attr("src") else {
                // Log.warning(message: "...") // Will address log calls later
                log(.warning, "SMILParser: Skipping <par> element (id: \(parElement.attr("id") ?? "N/A")) due to missing text or audio src.")
                return nil
            }

            // Error: Value of type 'MediaOverlayNode' has no member 'audio'
            // Fix: We need to create the Clip first, then create MediaOverlayNode with it.
            // let node = MediaOverlayNode() <--- Problematic if trying to set .audio later
            // node.role.append("paragraph")

            var resolvedTextSrc: String?
            if let textURL = RelativeURL(string: textSrcWithFragment) {
                resolvedTextSrc = baseHREF?.resolve(textURL)?.string ?? textSrcWithFragment
            } else {
                resolvedTextSrc = textSrcWithFragment
            }

            // Error: Value of type 'Clip' has no member 'src'
            // Error: Value of type 'Clip' has no member 'clipBegin'
            // Fix: Create Clip and set its properties, then pass it to MediaOverlayNode init.
            var newClip = Clip() // Use the public empty init()

            if let audioURL = RelativeURL(string: audioSrc) {
                // Assuming `relativeUrl` is the correct property name in your Clip struct for the audio source.
                // It expects a URL, not a String.
                if let resolvedURL = baseHREF?.resolve(audioURL)?.url {
                     newClip.relativeUrl = resolvedURL
                } else if let directURL = URL(string: audioSrc) { // Fallback if baseHREF is nil or resolution fails
                    newClip.relativeUrl = directURL
                } else {
                    log(.warning, "SMILParser: Could not form a valid URL for audio src: \(audioSrc)")
                    // Decide if this is a critical error; if relativeUrl is non-optional and !
                    // then this path must be avoided or an error thrown.
                    // For now, we might return nil if the audio src is invalid.
                    return nil
                }
            } else if let directURL = URL(string: audioSrc) { // If audioSrc is already absolute
                 newClip.relativeUrl = directURL
            } else {
                log(.warning, "SMILParser: Could not form a valid URL for audio src: \(audioSrc)")
                return nil // Or handle error appropriately
            }


            newClip.start = parseSMILClockValue(audioElement.attr("clipBegin"))
            newClip.end = parseSMILClockValue(audioElement.attr("clipEnd"))
            
            // Calculate duration if start and end are valid
            if let start = newClip.start, let end = newClip.end {
                newClip.duration = end - start
            } else {
                newClip.duration = 0 // Or nil if duration is optional
            }
            // The fragmentId for the clip is set in MediaOverlayNode's init: `self.clip?.fragmentId = fragmentId()`

            // Now create the MediaOverlayNode with the text and the fully formed clip
            let node = MediaOverlayNode(resolvedTextSrc, clip: newClip)
            node.role.append("paragraph") // You can still modify role and children after init

            // node.smilID = parElement.attr("id") // Example if you add smilID

            return node
        }

    /// Parses SMIL clock values into seconds (Double).
    /// Handles formats like: "123.45s", "0:00:00.000", "02:03.456", "5ms", "2min", "1h".
    static func parseSMILClockValue(_ value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        var factor: Double = 1.0 // Default is seconds for bare numbers

        if text.hasSuffix("ms") {
            factor = 0.001; text = String(text.dropLast(2))
        } else if text.hasSuffix("s") {
            factor = 1.0; text = String(text.dropLast())
        } else if text.hasSuffix("min") {
            factor = 60.0; text = String(text.dropLast(3))
        } else if text.hasSuffix("h") {
            factor = 3600.0; text = String(text.dropLast())
        }

        // Check for full/partial clock format (hh:mm:ss.xxx)
        if text.contains(":") {
            let components = text.split(separator: ":").map { String($0) }
            var seconds: Double = 0
            if components.count == 3 { // hh:mm:ss.fraction
                seconds += (Double(components[0]) ?? 0) * 3600
                seconds += (Double(components[1]) ?? 0) * 60
                seconds += Double(components[2]) ?? 0
            } else if components.count == 2 { // mm:ss.fraction
                seconds += (Double(components[0]) ?? 0) * 60
                seconds += Double(components[1]) ?? 0
            } else if components.count == 1 { // Potentially malformed, but could be just seconds
                seconds += Double(components[0]) ?? 0
            } else {
                return nil
            }
            return seconds // Factor already applied if units were h, min, s. For clock format, factor is 1.
        }

        // If not clock format, try to parse as a simple number with optional unit factor
        if let val = Double(text) {
            return val * factor
        }

        return nil
    }
}
