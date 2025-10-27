#if !os(Windows)
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses a UPnP device description document in order to discover Internet Gateway services.
final class UPnPDeviceDescriptionParser: NSObject {
    private let baseURL: URL

    /// Creates a parser rooted at the supplied base URL.
    /// - Parameter baseURL: URL of the description document used to resolve relative control URLs.
    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Parses the provided XML data and extracts WAN services.
    /// - Parameter data: Raw XML document representing the device description.
    /// - Returns: A list of service descriptions found in the document.
    func parse(data: Data) throws -> [UPnPServiceDescription] {
        let delegate = ParserDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let success = parser.parse()
        if success {
            return delegate.services
        }
        if let error = parser.parserError {
            throw error
        }
        throw NSError(domain: "box.upnp", code: 1, userInfo: [NSLocalizedDescriptionKey: "unable to parse UPnP description"])
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    private(set) var services: [UPnPServiceDescription] = []
    private let baseURL: URL

    private var insideService = false
    private var currentServiceType: String?
    private var currentControlURL: String?
    private var currentText: String?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = Self.localName(from: elementName, qualifiedName: qName)
        switch localName {
        case "service":
            insideService = true
            currentServiceType = nil
            currentControlURL = nil
        case "serviceType", "controlURL":
            if insideService {
                currentText = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentText != nil else { return }
        currentText?.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = Self.localName(from: elementName, qualifiedName: qName)
        switch localName {
        case "serviceType":
            if insideService {
                currentServiceType = currentText?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "controlURL":
            if insideService {
                currentControlURL = currentText?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "service":
            if insideService,
               let type = currentServiceType,
               let control = currentControlURL,
               let controlURL = Self.resolve(control, relativeTo: baseURL) {
                services.append(UPnPServiceDescription(serviceType: type, controlURL: controlURL))
            }
            insideService = false
            currentServiceType = nil
            currentControlURL = nil
        default:
            break
        }
        currentText = nil
    }

    private static func localName(from elementName: String, qualifiedName: String?) -> String {
        if let qualifiedName, let last = qualifiedName.split(separator: ":").last {
            return String(last)
        }
        if let last = elementName.split(separator: ":").last {
            return String(last)
        }
        return elementName
    }

    private static func resolve(_ controlURL: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: controlURL), absolute.scheme != nil {
            return absolute
        }
        return URL(string: controlURL, relativeTo: baseURL)?.absoluteURL
    }
}
#endif
