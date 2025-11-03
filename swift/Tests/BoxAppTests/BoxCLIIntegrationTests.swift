import XCTest
import Foundation
import Dispatch
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import BoxCore
@testable import BoxServer

final class BoxCLIIntegrationTests: XCTestCase {

    func testAdminPingCLI() async throws {
        try await runWithinTimeout {
            let context = try await startServer()
            defer { context.tearDown() }

            try await context.waitForAdminSocket()

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(args: ["admin", "ping", "--socket", context.socketPath], configurationPath: context.configurationURL.path)
            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)

            let json = try decodeJSON(stdout)
            XCTAssertEqual(json["status"] as? String, "ok")
            let message = try XCTUnwrap(json["message"] as? String)
            XCTAssertTrue(message.hasPrefix("pong"))
            XCTAssertTrue(message.contains(BoxVersionInfo.version), "Expected ping message to include version, got: \(message)")
        }
    }

    func testPingRootsDisplaysVersion() async throws {
        try await runWithinTimeout {
            let port = try allocateEphemeralUDPPort()
            let context = try await startServer(forcedPort: port)
            defer { context.tearDown() }

            try await context.waitForQueueInfrastructure()

            let fileManager = FileManager.default
            let tempHome = fileManager.temporaryDirectory.appendingPathComponent("box-ping-roots-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempHome, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempHome) }

            let environment = ["HOME": tempHome.path]

            _ = try await Self.runBoxCLIAsync(args: ["init-config", "--json"], environment: environment)

            var configurationResult = try BoxConfiguration.load(from: tempHome.appendingPathComponent(".box/Box.plist"))
            configurationResult.configuration.common.rootServers = [
                BoxRuntimeOptions.RootServer(address: "127.0.0.1", port: port)
            ]
            try configurationResult.configuration.save(to: configurationResult.url)

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: ["ping-roots", "--path", configurationResult.url.path],
                environment: environment
            )

            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)
            XCTAssertTrue(stdout.contains("127.0.0.1:\(port)"), "expected stdout to contain endpoint, got: \(stdout)")
            XCTAssertTrue(stdout.contains(BoxVersionInfo.version), "expected stdout to contain version \(BoxVersionInfo.version), got: \(stdout)")
        }
    }

    func testVersionFlagOutputsBuildInfo() async throws {
        try await runWithinTimeout {
            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(args: ["-v"])
            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.isEmpty)
            let parts = trimmed.split(separator: " ")
            XCTAssertGreaterThanOrEqual(parts.count, 4, "Expected at least four components in version output")
        }
    }

    func testAdminStatusCLI() async throws {
        try await runWithinTimeout {
            let context = try await startServer()
            defer { context.tearDown() }

            try await context.waitForAdminSocket()

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(args: ["admin", "status", "--socket", context.socketPath], configurationPath: context.configurationURL.path)
            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)

            let json = try decodeJSON(stdout)
            XCTAssertEqual(json["status"] as? String, "ok")
            XCTAssertNotNil(json["nodeUUID"])
            XCTAssertNotNil(json["userUUID"])
            let summary = try XCTUnwrap(coerceDictionary(json["locationService"]))
            XCTAssertNotNil(summary["totalNodes"])
            XCTAssertNotNil(summary["staleThresholdSeconds"])
        }
    }

    func testAdminLocateCLI() async throws {
        try await runWithinTimeout {
            let context = try await startServer()
            defer { context.tearDown() }

            try await context.waitForAdminSocket()

            let (statusStdout, statusStderr, statusCode) = try await Self.runBoxCLIAsync(
                args: ["admin", "status", "--socket", context.socketPath],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(statusCode, 0)
            XCTAssertTrue(statusStderr.isEmpty)
            let statusJSON = try decodeJSON(statusStdout)
            let nodeUUID = try XCTUnwrap(statusJSON["nodeUUID"] as? String)
            let userUUID = try XCTUnwrap(statusJSON["userUUID"] as? String)

            let (locateNodeStdout, locateNodeStderr, locateNodeStatus) = try await Self.runBoxCLIAsync(
                args: ["admin", "locate", nodeUUID, "--socket", context.socketPath],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(locateNodeStatus, 0)
            XCTAssertTrue(locateNodeStderr.isEmpty)
            let locateNodeJSON = try decodeJSON(locateNodeStdout)
            XCTAssertEqual(locateNodeJSON["status"] as? String, "ok")
            let record = try XCTUnwrap(coerceDictionary(locateNodeJSON["record"]))
            XCTAssertEqual(record["node_uuid"] as? String ?? record["nodeUUID"] as? String, nodeUUID)
            XCTAssertEqual(record["user_uuid"] as? String ?? record["userUUID"] as? String, userUUID)
            XCTAssertNotNil(record["node_public_key"] ?? record["nodePublicKey"], "Expected node public key in record")
            XCTAssertNotNil(coerceArrayOfDictionaries(record["addresses"]))
            XCTAssertNotNil(coerceDictionary(record["connectivity"]))

            let (locateUserStdout, locateUserStderr, locateUserStatus) = try await Self.runBoxCLIAsync(
                args: ["admin", "locate", userUUID, "--socket", context.socketPath],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(locateUserStatus, 0)
            XCTAssertTrue(locateUserStderr.isEmpty)
            let locateUserJSON = try decodeJSON(locateUserStdout)
            XCTAssertEqual(locateUserJSON["status"] as? String, "ok")
            let userPayload = try XCTUnwrap(coerceDictionary(locateUserJSON["user"]))
            XCTAssertEqual(userPayload["userUUID"] as? String ?? userPayload["user_uuid"] as? String, userUUID)
            let nodeUUIDs = userPayload["nodeUUIDs"] as? [String]
                ?? (userPayload["node_uuid_list"] as? [String])
                ?? (userPayload["nodeUUIDs"] as? [NSString])?.map { $0 as String }
            XCTAssertNotNil(nodeUUIDs)
            XCTAssertEqual(nodeUUIDs?.contains(nodeUUID), true)
            let userRecords = try XCTUnwrap(coerceArrayOfDictionaries(userPayload["records"]))
            XCTAssertFalse(userRecords.isEmpty)

            let randomUUID = UUID().uuidString
            let (missingStdout, missingStderr, missingStatus) = try await Self.runBoxCLIAsync(
                args: ["admin", "locate", randomUUID, "--socket", context.socketPath],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(missingStatus, 0)
            XCTAssertTrue(missingStderr.isEmpty)
            let missingJSON = try decodeJSON(missingStdout)
            XCTAssertEqual(missingJSON["status"] as? String, "error")
            XCTAssertEqual(missingJSON["message"] as? String, "node-not-found")
        }
    }

    func testAdminNatProbeCLI() async throws {
        try await runWithinTimeout {
            let context = try await startServer()
            defer { context.tearDown() }

            try await context.waitForAdminSocket()

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: ["admin", "nat-probe", "--socket", context.socketPath],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)

            let json = try decodeJSON(stdout)
            let reportedStatus = json["status"] as? String
            XCTAssertNotNil(reportedStatus)
            XCTAssertTrue(
                reportedStatus == "disabled" || reportedStatus == "skipped",
                "Unexpected nat-probe status: \(reportedStatus ?? "nil")"
            )
            let reports = coerceArrayOfDictionaries(json["reports"])
            XCTAssertNotNil(reports)
        }
    }

    func testClientPutAndGetRoundTripViaCLI() async throws {
        try await runWithinTimeout {
            let chosenPort = try allocateEphemeralUDPPort()
            let configurationData = try makeCLIConfigurationData(port: chosenPort)
            let context = try await startServer(configurationData: configurationData, forcedPort: chosenPort)
            defer { context.tearDown() }

            try await context.waitForAdminSocket()
            try await context.waitForQueueInfrastructure()

            let logsDirectory = context.homeDirectory.appendingPathComponent(".box/logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let clientLogURL = logsDirectory.appendingPathComponent("cli-put-get.log", isDirectory: false)
            var configurationResult = try BoxConfiguration.load(from: context.configurationURL)
            configurationResult.configuration.client.address = "127.0.0.1"
            configurationResult.configuration.client.port = chosenPort
            configurationResult.configuration.client.logTarget = "file:\(clientLogURL.path)"
            try configurationResult.configuration.save(to: configurationResult.url)
            let configuration = configurationResult.configuration

            let payloadString = "CLI integration payload"
            let targetNodeUUID = configuration.common.nodeUUID.uuidString

            let (putStdout, putStderr, putStatus) = try await Self.runBoxCLIAsync(
                args: [
                    "put",
                    "at", targetNodeUUID,
                    "queue", "INBOX",
                    payloadString,
                    "as", "text/plain"
                ],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(putStatus, 0)
            XCTAssertTrue(putStdout.isEmpty)
            XCTAssertTrue(putStderr.isEmpty)

            let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
            let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.cli.putget"))
            let references = try await store.list(queue: "INBOX")
            XCTAssertEqual(references.count, 1, "Expected exactly one stored message after CLI PUT")
            let storedObject = try await store.read(reference: try XCTUnwrap(references.first))
            XCTAssertEqual(String(bytes: storedObject.data, encoding: .utf8), payloadString)
            XCTAssertEqual(storedObject.contentType, "text/plain")
            XCTAssertEqual(storedObject.nodeId, configuration.common.nodeUUID)
            XCTAssertEqual(storedObject.userId, configuration.common.userUUID)

            let (getStdout, getStderr, getStatus) = try await Self.runBoxCLIAsync(
                args: [
                    "get",
                    "from", targetNodeUUID,
                    "queue", "INBOX"
                ],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(getStatus, 0)
            XCTAssertTrue(getStdout.isEmpty)
            XCTAssertTrue(getStderr.isEmpty)

            let remaining = try await store.list(queue: "INBOX")
            XCTAssertTrue(remaining.isEmpty, "GET via CLI should consume messages on non-permanent queues")
        }
    }

    func testClientGetPreservesPermanentQueueViaCLI() async throws {
        try await runWithinTimeout {
            let chosenPort = try allocateEphemeralUDPPort()
            let configurationData = try makeCLIConfigurationData(port: chosenPort, permanentQueues: ["INBOX"])
            let context = try await startServer(configurationData: configurationData, forcedPort: chosenPort)
            defer { context.tearDown() }

            try await context.waitForAdminSocket()
            try await context.waitForQueueInfrastructure()

            let logsDirectory = context.homeDirectory.appendingPathComponent(".box/logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let clientLogURL = logsDirectory.appendingPathComponent("cli-permanent.log", isDirectory: false)
            var configurationResult = try BoxConfiguration.load(from: context.configurationURL)
            configurationResult.configuration.client.address = "127.0.0.1"
            configurationResult.configuration.client.port = chosenPort
            configurationResult.configuration.client.logTarget = "file:\(clientLogURL.path)"
            try configurationResult.configuration.save(to: configurationResult.url)
            let configuration = configurationResult.configuration
            let targetNodeUUID = configuration.common.nodeUUID.uuidString

            let payloadString = "Persistent CLI payload"
            let (putStdout, putStderr, putStatus) = try await Self.runBoxCLIAsync(
                args: [
                    "put",
                    "at", targetNodeUUID,
                    "queue", "INBOX",
                    payloadString,
                    "as", "text/plain"
                ],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(putStatus, 0)
            XCTAssertTrue(putStdout.isEmpty)
            XCTAssertTrue(putStderr.isEmpty)

            let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
            let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.cli.permanent"))
            let references = try await store.list(queue: "INBOX")
            XCTAssertEqual(references.count, 1, "Expected stored message after CLI PUT on permanent queue")

            let storedReference = try XCTUnwrap(references.first)
            let storedObject = try await store.read(reference: storedReference)
            XCTAssertEqual(String(bytes: storedObject.data, encoding: .utf8), payloadString)

            for attempt in 1...2 {
                let (getStdout, getStderr, getStatus) = try await Self.runBoxCLIAsync(
                    args: [
                        "get",
                        "from", targetNodeUUID,
                        "queue", "INBOX"
                    ],
                    configurationPath: context.configurationURL.path
                )
                XCTAssertEqual(getStatus, 0, "GET attempt \(attempt) should succeed")
                XCTAssertTrue(getStdout.isEmpty)
                XCTAssertTrue(getStderr.isEmpty)

                let remaining = try await store.list(queue: "INBOX")
                XCTAssertEqual(remaining.count, 1, "Permanent queue should retain message after GET attempt \(attempt)")
                let object = try await store.read(reference: storedReference)
                XCTAssertEqual(String(bytes: object.data, encoding: .utf8), payloadString)
            }
        }
    }

    func testAdminLocationSummaryCLI() async throws {
        try await runWithinTimeout {
            let context = try await startServer()
            defer { context.tearDown() }

            try await context.waitForAdminSocket()

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: ["admin", "location-summary", "--socket", context.socketPath],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)
            XCTAssertTrue(stdout.contains("Location Service Summary"))
            XCTAssertTrue(stdout.contains("totalNodes"))

            let (jsonStdout, jsonStderr, jsonStatus) = try await Self.runBoxCLIAsync(
                args: ["admin", "location-summary", "--socket", context.socketPath, "--json"],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(jsonStatus, 0)
            XCTAssertTrue(jsonStderr.isEmpty)
            let summaryJSON = try decodeJSON(jsonStdout)
            XCTAssertNotNil(summaryJSON["totalNodes"])
        }
    }

    func testAdminLocationSummaryFailOnStale() async throws {
        try await runWithinTimeout {
            let context = try await startServer()
            defer { context.tearDown() }

            try await context.waitForAdminSocket()
            try await context.waitForQueueInfrastructure()

            let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
            let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.cli.summary"))
            _ = try await store.ensureQueue("/whoswho")

            let staleUser = UUID()
            let staleNode = UUID()
            let staleRecord = LocationServiceNodeRecord.make(
                userUUID: staleUser,
                nodeUUID: staleNode,
                port: 12567,
                probedGlobalIPv6: [],
                ipv6Error: nil,
                portMappingEnabled: false,
                portMappingOrigin: .default,
                online: true,
                since: 0,
                lastSeen: 0
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let recordData = try encoder.encode(staleRecord)
            let storedObject = BoxStoredObject(
                id: staleRecord.nodeUUID,
                contentType: "application/json; charset=utf-8",
                data: [UInt8](recordData),
                nodeId: staleRecord.nodeUUID,
                userId: staleRecord.userUUID,
                userMetadata: ["schema": "box.location-service.v1"]
            )
            try? await store.remove(queue: "/whoswho", id: staleRecord.nodeUUID)
            _ = try await store.put(storedObject, into: "/whoswho")

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: ["admin", "location-summary", "--socket", context.socketPath, "--fail-on-stale"],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(status, 2)
            XCTAssertTrue(stderr.isEmpty)
            XCTAssertTrue(stdout.contains(staleNode.uuidString))
        }
    }

    func testAdminLocationSummaryPrometheus() async throws {
        try await runWithinTimeout {
            let context = try await startServer()
            defer { context.tearDown() }

            try await context.waitForAdminSocket()

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: ["admin", "location-summary", "--socket", context.socketPath, "--prometheus"],
                configurationPath: context.configurationURL.path
            )

            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)
            XCTAssertTrue(stdout.contains("box_location_nodes_total"), "Expected Prometheus gauge output")
            XCTAssertTrue(stdout.contains("# TYPE box_location_nodes_total gauge"))
        }
    }

    func testInitConfigCLI() async throws {
        try await runWithinTimeout {
            let fileManager = FileManager.default
            let tempHome = fileManager.temporaryDirectory.appendingPathComponent("box-init-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempHome, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempHome) }

            let overrides = ["HOME": tempHome.path]

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: ["init-config", "--json"],
                environment: overrides
            )
            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)
            let summary = try decodeJSON(stdout)
            let path = try XCTUnwrap(summary["path"] as? String)
            XCTAssertEqual(summary["created"] as? Bool, true)
            XCTAssertEqual(summary["rotated"] as? Bool, false)
            let firstNode = try XCTUnwrap(summary["nodeUUID"] as? String)
            let firstUser = try XCTUnwrap(summary["userUUID"] as? String)
            XCTAssertEqual(summary["userIdentityRotated"] as? Bool, true)
            XCTAssertEqual(summary["nodeIdentityRotated"] as? Bool, true)
            XCTAssertTrue(fileManager.fileExists(atPath: path))

            let linksURL = tempHome.appendingPathComponent(".box/keys/identity-links.json", isDirectory: false)
            XCTAssertTrue(fileManager.fileExists(atPath: linksURL.path))
            let linksData = try Data(contentsOf: linksURL)
            let linksJSON = try decodeJSON(String(data: linksData, encoding: .utf8) ?? "{}")
            XCTAssertEqual(linksJSON["userUUID"] as? String, firstUser.uppercased())
            XCTAssertEqual(linksJSON["nodeUUID"] as? String, firstNode.uppercased())

            let (secondStdout, secondStderr, secondStatus) = try await Self.runBoxCLIAsync(
                args: ["init-config", "--json"],
                environment: overrides
            )
            XCTAssertEqual(secondStatus, 0)
            XCTAssertTrue(secondStderr.isEmpty)
            let secondSummary = try decodeJSON(secondStdout)
            XCTAssertEqual(secondSummary["created"] as? Bool, false)
            XCTAssertEqual(secondSummary["rotated"] as? Bool, false)
            XCTAssertEqual(secondSummary["nodeUUID"] as? String, firstNode)
            XCTAssertEqual(secondSummary["userUUID"] as? String, firstUser)
            XCTAssertEqual(secondSummary["userIdentityRotated"] as? Bool, false)
            XCTAssertEqual(secondSummary["nodeIdentityRotated"] as? Bool, false)

            let (thirdStdout, thirdStderr, thirdStatus) = try await Self.runBoxCLIAsync(
                args: ["init-config", "--json", "--rotate-identities"],
                environment: overrides
            )
            XCTAssertEqual(thirdStatus, 0)
            XCTAssertTrue(thirdStderr.isEmpty)
            let thirdSummary = try decodeJSON(thirdStdout)
            XCTAssertEqual(thirdSummary["rotated"] as? Bool, true)
            XCTAssertNotEqual(thirdSummary["nodeUUID"] as? String, firstNode)
            XCTAssertNotEqual(thirdSummary["userUUID"] as? String, firstUser)
            XCTAssertEqual(thirdSummary["userIdentityRotated"] as? Bool, true)
            XCTAssertEqual(thirdSummary["nodeIdentityRotated"] as? Bool, true)
        }
    }

    func testInitConfigRespectsProvidedUserUUID() async throws {
        try await runWithinTimeout {
            let fileManager = FileManager.default
            let tempHome = fileManager.temporaryDirectory.appendingPathComponent("box-init-provided-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempHome, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempHome) }

            let overrides = ["HOME": tempHome.path]
            let existingUser = UUID()

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: ["init-config", "--json", "--user-uuid", existingUser.uuidString],
                environment: overrides
            )
            XCTAssertEqual(status, 0)
            XCTAssertTrue(stderr.isEmpty)
            let summary = try decodeJSON(stdout)
            XCTAssertEqual(summary["userUUID"] as? String, existingUser.uuidString)
            XCTAssertEqual(summary["userIdentityRotated"] as? Bool, true)

            let plistURL = tempHome.appendingPathComponent(".box/Box.plist")
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as? [String: Any]
            let common = plist?["common"] as? [String: Any]
            XCTAssertEqual(common?["user_uuid"] as? String, existingUser.uuidString.uppercased())

            let linksURL = tempHome.appendingPathComponent(".box/keys/identity-links.json", isDirectory: false)
            let linksData = try Data(contentsOf: linksURL)
            let linksJSON = try decodeJSON(String(data: linksData, encoding: .utf8) ?? "{}")
            XCTAssertEqual(linksJSON["userUUID"] as? String, existingUser.uuidString.uppercased())

            let (secondStdout, secondStderr, secondStatus) = try await Self.runBoxCLIAsync(
                args: ["init-config", "--json"],
                environment: overrides
            )
            XCTAssertEqual(secondStatus, 0)
            XCTAssertTrue(secondStderr.isEmpty)
            let secondSummary = try decodeJSON(secondStdout)
            XCTAssertEqual(secondSummary["userUUID"] as? String, existingUser.uuidString)
            XCTAssertEqual(secondSummary["userIdentityRotated"] as? Bool, false)
        }
    }

    func testClientLocateCLI() async throws {
        try await runWithinTimeout {
            let chosenPort = try allocateEphemeralUDPPort()
            let context = try await startServer(forcedPort: chosenPort)
            defer { context.tearDown() }

            try await context.waitForAdminSocket()
            try await context.waitForQueueInfrastructure()

            let (statusStdout, statusStderr, statusCode) = try await Self.runBoxCLIAsync(
                args: ["admin", "status", "--socket", context.socketPath],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(statusCode, 0)
            XCTAssertTrue(statusStderr.isEmpty)
            let statusJSON = try decodeJSON(statusStdout)
            let serverNodeUUID = try XCTUnwrap(statusJSON["nodeUUID"] as? String)
            let contactIP = "127.0.0.1"
            let contactPort = chosenPort

            let clientNodeUUID = UUID()
            let clientUserUUID = UUID()

            let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
            let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.cli.locate"))
            _ = try await store.ensureQueue("/whoswho")

            let record = LocationServiceNodeRecord.make(
                userUUID: clientUserUUID,
                nodeUUID: clientNodeUUID,
                port: contactPort,
                probedGlobalIPv6: [],
                ipv6Error: nil,
                portMappingEnabled: false,
                portMappingOrigin: .default,
                additionalAddresses: [
                    LocationServiceNodeRecord.Address(ip: contactIP, port: contactPort, scope: .loopback, source: .manual)
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let recordData = try encoder.encode(record)
            let storedObject = BoxStoredObject(
                id: record.nodeUUID,
                contentType: "application/json; charset=utf-8",
                data: [UInt8](recordData),
                nodeId: record.nodeUUID,
                userId: record.userUUID,
                userMetadata: ["schema": "box.location-service.v1"]
            )
            try? await store.remove(queue: "/whoswho", id: record.nodeUUID)
            try await store.put(storedObject, into: "/whoswho")

            var configurationResult = try BoxConfiguration.load(from: context.configurationURL)
            configurationResult.configuration.common = .init(nodeUUID: clientNodeUUID, userUUID: clientUserUUID)
            configurationResult.configuration.client.address = "127.0.0.1"
            configurationResult.configuration.client.port = contactPort
            try configurationResult.configuration.save(to: configurationResult.url)

            let (locateStdout, locateStderr, locateStatus) = try await Self.runBoxCLIAsync(
                args: [
                    "locate",
                    serverNodeUUID
                ],
                configurationPath: context.configurationURL.path
            )
            XCTAssertEqual(locateStatus, 0)
            XCTAssertTrue(locateStderr.isEmpty, "Unexpected stderr output: \(locateStderr)")
            XCTAssertTrue(locateStdout.isEmpty)

            let clientLogURL = context.homeDirectory
                .appendingPathComponent(".box/logs/box.log", isDirectory: false)
            let logData = try String(contentsOf: clientLogURL, encoding: .utf8)
            XCTAssertTrue(logData.contains("LOCATE response"), "Expected LOCATE response in client logs file")
            XCTAssertTrue(logData.contains(serverNodeUUID), "Expected server node UUID in client logs file")
        }
    }

    func testRegisterPublishesRecordsToRoot() async throws {
        try await runWithinTimeout {
            let port = try allocateEphemeralUDPPort()
            let context = try await startServer(forcedPort: port)
            defer { context.tearDown() }

            try await context.waitForQueueInfrastructure()

            let fileManager = FileManager.default
            let tempHome = fileManager.temporaryDirectory.appendingPathComponent("box-register-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempHome, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempHome) }

            let env = ["HOME": tempHome.path]

            _ = try await Self.runBoxCLIAsync(args: ["init-config", "--json"], environment: env)

            var configurationResult = try BoxConfiguration.load(from: tempHome.appendingPathComponent(".box/Box.plist"))
            configurationResult.configuration.common.rootServers = [
                BoxRuntimeOptions.RootServer(address: "127.0.0.1", port: port)
            ]
            configurationResult.configuration.server.externalAddress = "127.0.0.1"
            configurationResult.configuration.server.externalPort = port
            configurationResult.configuration.server.port = port
            try configurationResult.configuration.save(to: configurationResult.url)

            let nodeID = configurationResult.configuration.common.nodeUUID
            let userID = configurationResult.configuration.common.userUUID

            let (stdout, stderr, status) = try await Self.runBoxCLIAsync(
                args: [
                    "register",
                    "--path", configurationResult.url.path,
                    "--address", "127.0.0.1",
                    "--port", "\(port)",
                    "--root", "127.0.0.1:\(port)"
                ],
                environment: env
            )
            guard status == 0 else {
                XCTFail("register failed with status \(status): \(stderr)")
                return
            }
            XCTAssertTrue(stdout.contains("127.0.0.1"))

            let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
            let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.cli.register"))
            let entries = try await store.list(queue: "/whoswho")

            var foundNodeRecord = false
            var foundUserRecord = false

            for reference in entries {
                let object = try await store.read(reference: reference)
                let data = Data(object.data)
                let decoder = JSONDecoder()
                if let nodeRecord = try? decoder.decode(LocationServiceNodeRecord.self, from: data) {
                    if nodeRecord.nodeUUID == nodeID && nodeRecord.userUUID == userID {
                        foundNodeRecord = true
                    }
                    continue
                }
                if let userRecord = try? decoder.decode(LocationServiceUserRecord.self, from: data) {
                    if userRecord.userUUID == userID {
                        XCTAssertTrue(userRecord.nodeUUIDs.contains(nodeID))
                        foundUserRecord = true
                    }
                }
            }

            XCTAssertTrue(foundNodeRecord, "Node record not found in whoswho queue")
            XCTAssertTrue(foundUserRecord, "User record not found in whoswho queue")

            let localUserURL = tempHome.appendingPathComponent(".box/queues/whoswho/\(userID.uuidString.uppercased()).json")
            XCTAssertTrue(fileManager.fileExists(atPath: localUserURL.path))
        }
    }

    func testClientPutUnauthorizedReportsRemoteMessage() async throws {
        try await runWithinTimeout {
            let port = try allocateEphemeralUDPPort()
            let context = try await startServer(forcedPort: port)
            defer { context.tearDown() }

            try await context.waitForQueueInfrastructure()

            let fileManager = FileManager.default
            let clientHome = fileManager.temporaryDirectory
                .appendingPathComponent("box-cli-unauth-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: clientHome, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: clientHome) }

            let environment = ["HOME": clientHome.path]

            _ = try await Self.runBoxCLIAsync(args: ["init-config", "--json"], environment: environment)

            let serverConfiguration = try BoxConfiguration.load(from: context.configurationURL).configuration
            let targetNodeUUID = serverConfiguration.common.nodeUUID.uuidString

            let clientConfigURL = clientHome.appendingPathComponent(".box/Box.plist")
            var clientConfiguration = try BoxConfiguration.load(from: clientConfigURL)
            clientConfiguration.configuration.client.address = "127.0.0.1"
            clientConfiguration.configuration.client.port = port
            try clientConfiguration.configuration.save(to: clientConfiguration.url)

            let (_, stderr, status) = try await Self.runBoxCLIAsync(
                args: [
                    "put",
                    "at", targetNodeUUID,
                    "queue", "INBOX",
                    "hello",
                    "as", "text/plain"
                ],
                environment: environment
            )

            XCTAssertNotEqual(status, 0)
            XCTAssertTrue(stderr.contains("Failed to deliver message"), "Expected friendly rejection message, got: \(stderr)")
            XCTAssertTrue(stderr.contains("unknown-client"), "Expected server reason in stderr, got: \(stderr)")
        }
    }

    // Helper to run the box CLI tool
    private static func runBoxCLIAsync(args: [String], configurationPath: String? = nil, environment: [String: String]? = nil) async throws -> (String, String, Int32) {
        let boxBinary = productsDirectory.appendingPathComponent("box")

        let process = Process()
        process.executableURL = boxBinary
        if let configurationPath {
            process.arguments = ["--config", configurationPath] + args
        } else {
            process.arguments = args
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let errorPipe = Pipe()
        process.standardError = errorPipe

        var environmentVariables = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                environmentVariables[key] = value
            }
        }
        process.environment = environmentVariables

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, error, proc.terminationStatus))
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Returns path to the built products directory.
    static var productsDirectory: URL {
      #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("couldn\'t find the products directory")
      #else
        return Bundle.main.bundleURL
      #endif
    }
}

private func makeCLIConfigurationData(port: UInt16, permanentQueues: [String] = []) throws -> Data {
    let nodeUUID = UUID().uuidString
    let userUUID = UUID().uuidString
    var serverSection: [String: Any] = [
        "port": port,
        "log_level": "info",
        "log_target": "stderr",
        "admin_channel": true,
        "port_mapping": false,
        "permanent_queues": permanentQueues
    ]
    if permanentQueues.isEmpty {
        serverSection["permanent_queues"] = []
    }
    let plist: [String: Any] = [
        "common": [
            "node_uuid": nodeUUID,
            "user_uuid": userUUID
        ],
        "server": serverSection,
        "client": [
            "address": "127.0.0.1",
            "port": port,
            "log_level": "info",
            "log_target": "stderr"
        ]
    ]
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

private func decodeJSON(_ response: String) throws -> [String: Any] {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else {
        throw NSError(domain: "BoxCLIIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "response is not UTF-8"])
    }
    let object = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dictionary = object as? [String: Any] else {
        throw NSError(domain: "BoxCLIIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "response is not a JSON object"])
    }
    return dictionary
}

/// Converts an arbitrary JSON object into a Swift dictionary when possible.
/// - Parameter value: The value returned by `JSONSerialization`.
/// - Returns: A `[String: Any]` representation when the value is bridgeable.
private func coerceDictionary(_ value: Any?) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        return dictionary
    }
    if let nsDictionary = value as? NSDictionary {
        var result: [String: Any] = [:]
        for case let (key as String, element) in nsDictionary {
            result[key] = element
        }
        return result
    }
    return nil
}

/// Extracts the primary contact endpoint (IP + port) from an admin status payload.
/// - Parameter statusJSON: JSON dictionary obtained from `box admin status`.
/// - Returns: Tuple describing the contact IP and UDP port.
private func extractPrimaryEndpoint(from statusJSON: [String: Any]) throws -> (String, UInt16) {
    guard let addresses = coerceArrayOfDictionaries(statusJSON["addresses"]), !addresses.isEmpty else {
        throw NSError(domain: "BoxCLIIntegrationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "missing addresses in status payload"])
    }

    func port(from value: Any?) -> UInt16? {
        switch value {
        case let number as NSNumber:
            return UInt16(clamping: number.intValue)
        case let string as String:
            return UInt16(string)
        default:
            return nil
        }
    }

    let preferred = addresses.first { ($0["scope"] as? String)?.lowercased() == "loopback" } ?? addresses.first
    guard let entry = preferred, let extractedPort = port(from: entry["port"]) else {
        throw NSError(domain: "BoxCLIIntegrationTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid address entry in status payload"])
    }

    let scope = entry["scope"] as? String
    let rawIP = (entry["ip"] as? String) ?? "127.0.0.1"
    let resolvedIP = (scope?.lowercased() == "loopback") ? rawIP : "127.0.0.1"

    return (resolvedIP, extractedPort)
}

// MARK: - Timeout helpers

private enum TestTimeoutError: Error, LocalizedError {
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "operation exceeded \(seconds) seconds timeout"
        }
    }
}

private func runWithinTimeout(seconds: TimeInterval = 30, _ body: @escaping @Sendable () async throws -> Void) async throws {
    try await withTimeout(seconds: seconds, operation: body)
}

private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TestTimeoutError.timedOut(seconds)
        }
        do {
            guard let result = try await group.next() else {
                throw TestTimeoutError.timedOut(seconds)
            }
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Converts an arbitrary JSON array into an array of dictionaries when possible.
/// - Parameter value: The value returned by `JSONSerialization`.
/// - Returns: An array of `[String: Any]` dictionaries when every element is bridgeable.
private func coerceArrayOfDictionaries(_ value: Any?) -> [[String: Any]]? {
    if let array = value as? [[String: Any]] {
        return array
    }
    if let nsArray = value as? [NSDictionary] {
        return nsArray.compactMap {
            coerceDictionary($0)
        }
    }
    if let genericArray = value as? [Any] {
        var result: [[String: Any]] = []
        for element in genericArray {
            guard let dictionary = coerceDictionary(element) else {
                return nil
            }
            result.append(dictionary)
        }
        return result
    }
    return nil
}
