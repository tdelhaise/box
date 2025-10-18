#if !os(Windows)
import Foundation
import XCTest
@testable import BoxServer

final class PortMappingUtilitiesTests: XCTestCase {
    func testParseSSDPResponseExtractsLocationCaseInsensitive() {
        let response = """
        HTTP/1.1 200 OK\r
        CACHE-CONTROL: max-age=120\r
        DATE: Sat, 18 Oct 2025 21:37:48 GMT\r
        EXT:\r
        LOCATION: http://192.168.1.1:1900/rootDesc.xml\r
        SERVER: Custom/1.0 UPnP/1.0 Proc/Ver\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        USN: uuid:12345678-1234-1234-1234-1234567890ab::urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        \r
        """
        let headers = PortMappingUtilities.parseSSDPResponse(Data(response.utf8))
        XCTAssertEqual(headers["location"], "http://192.168.1.1:1900/rootDesc.xml")
        XCTAssertEqual(headers["st"], "urn:schemas-upnp-org:device:InternetGatewayDevice:1")
    }

    func testDeviceDescriptionParserResolvesRelativeControlURL() throws {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
                <controlURL>/upnp/control/WANIPConn1</controlURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
                <controlURL>http://example.com:80/ppp</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
        let baseURL = URL(string: "http://192.168.1.1:1900/rootDesc.xml")!
        let parser = UPnPDeviceDescriptionParser(baseURL: baseURL)
        let services = try parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(services.count, 2)
        let wanIP = services.first { $0.serviceType == "urn:schemas-upnp-org:service:WANIPConnection:1" }
        XCTAssertEqual(wanIP?.controlURL.absoluteString, "http://192.168.1.1:1900/upnp/control/WANIPConn1")
        let wanPPP = services.first { $0.serviceType == "urn:schemas-upnp-org:service:WANPPPConnection:1" }
        XCTAssertEqual(wanPPP?.controlURL.absoluteString, "http://example.com:80/ppp")
    }

    func testEscapeXMLEncodesSpecialCharacters() {
        let original = "<tag attr=\"value\">Tom & Jerry's</tag>"
        let escaped = PortMappingUtilities.escapeXML(original)
        XCTAssertEqual(escaped, "&lt;tag attr=&quot;value&quot;&gt;Tom &amp; Jerry&apos;s&lt;/tag&gt;")
    }
}
#endif
