import Foundation

/// Small namespace-aware reader for capability discovery. Does not resolve external entities.
enum ONVIFZoomCapabilityParsing {
    private static let schema = "http://www.onvif.org/ver10/schema"
    private static let ptz = "http://www.onvif.org/ver20/ptz/wsdl"
    private static let media = "http://www.onvif.org/ver10/media/wsdl"

    static func configurationToken(_ data: Data, profileToken: String) throws -> String? {
        let root = try parse(data)
        return root.descendants(named: "Profiles", namespace: media)
            .first { $0.attributes["token"] == profileToken }?
            .children.first { $0.name == "PTZConfiguration" && $0.namespace == schema }?
            .attributes["token"]
    }

    static func supportsContinuousZoom(_ data: Data) throws -> Bool {
        let root = try parse(data)
        guard let response = root.descendants(named: "GetConfigurationOptionsResponse", namespace: ptz).first,
              let options = response.children.first(where: { $0.name == "PTZConfigurationOptions" && $0.namespace == ptz }),
              let spaces = options.children.first(where: { $0.name == "Spaces" && $0.namespace == schema }) else {
            throw ONVIFPTZError.parseError("Missing PTZ configuration options or spaces.")
        }
        // The client sends normalized velocities in VelocityGenericSpace. A camera must
        // advertise both zoom directions in that space for these controls to be usable.
        return spaces.children.filter { $0.name == "ContinuousZoomVelocitySpace" && $0.namespace == schema }.contains { space in
            let uri = space.children.first { $0.name == "URI" && $0.namespace == schema }?.trimmedText
            let range = space.children.first { $0.name == "XRange" && $0.namespace == schema }
            let minimum = range?.children.first { $0.name == "Min" && $0.namespace == schema }?.trimmedText
            let maximum = range?.children.first { $0.name == "Max" && $0.namespace == schema }?.trimmedText
            guard uri == "http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace",
                  let minimum, let maximum, let low = Double(minimum), let high = Double(maximum) else { return false }
            return low <= -0.65 && high >= 0.65
        }
    }

    private static func parse(_ data: Data) throws -> Node {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw ONVIFPTZError.parseError("Invalid capability XML.") }
        return reader.root
    }

    private final class Node {
        let name: String
        let namespace: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        init(name: String, namespace: String = "", attributes: [String: String] = [:]) {
            self.name = name
            self.namespace = namespace
            self.attributes = attributes
        }

        func descendants(named name: String, namespace: String) -> [Node] {
            children.flatMap { child in
                (child.name == name && child.namespace == namespace ? [child] : [])
                    + child.descendants(named: name, namespace: namespace)
            }
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let root = Node(name: "root")
        var stack: [Node] = []

        override init() {
            super.init()
            stack = [root]
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let node = Node(name: elementName, namespace: namespaceURI ?? "", attributes: attributeDict)
            stack.last?.children.append(node)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}
