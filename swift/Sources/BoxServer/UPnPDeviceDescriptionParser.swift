#if !os(Windows)
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class UPnPDeviceDescriptionParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var services: [UPnPServiceDescription] = []
    private var currentServiceType: String?
    private var currentControlURL: String?
    private var currentElement: String?
    private var accumulator = ""

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parse(data: Data) throws -> [UPnPServiceDescription] {
        services = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            return services
        }
        if let error = parser.parserError {
            throw error
        }
        return services
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        accumulator.removeAll(keepingCapacity: true)
        if elementName == "service" {
            currentServiceType = nil
            currentControlURL = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        accumulator.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "serviceType":
            currentServiceType = value
        case "controlURL":
            currentControlURL = value
        case "service":
            if let serviceType = currentServiceType, let urlString = currentControlURL,
               let resolvedURL = URL(string: urlString, relativeTo: baseURL)?.absoluteURL {
                services.append(UPnPServiceDescription(serviceType: serviceType, controlURL: resolvedURL))
            }
            currentServiceType = nil
            currentControlURL = nil
        default:
            break
        }
        currentElement = nil
    }
}
#endif
