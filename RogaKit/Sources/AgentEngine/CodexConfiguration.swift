import Foundation

/// What Roga reads in Codex's `config.toml`, as plain text, without a TOML
/// parser (decision 41). Roga never writes to it.
public enum CodexConfiguration {
    /// The MCP servers that a `config.toml` sets up, by name, each once, in
    /// the order they first appear.
    ///
    /// Generate turns each one off, because no flag of Codex turns them all
    /// off, and a server runs outside Codex's read-only sandbox, so a tool of
    /// its that asks for no approval could do something on instructions
    /// written into a diff. Starting them also costs time on every run.
    ///
    /// It finds the names in table headers, as in `[mcp_servers.docs]`,
    /// which is how `codex mcp add` writes them, in the keys of an
    /// `[mcp_servers]` table, and in dotted keys such as
    /// `mcp_servers.docs.command = "…"` before the first table. Only names
    /// that are bare TOML keys count, letters, digits, `-` and `_`, because
    /// Codex's `-c` splits its key at every dot, so it can't name any other.
    /// Codex refuses to start when `-c` names a server it doesn't have, so a
    /// name is never guessed.
    public static func mcpServers(in text: String) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        func add(_ name: String) {
            guard isBareKey(name), seen.insert(name).inserted else { return }
            names.append(name)
        }
        /// The table the lines belong to, as its key's parts.
        var table: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[[") {
                // An array of tables, which MCP servers never are.
                table = ["[["]
                continue
            }
            if trimmed.hasPrefix("[") {
                let header = trimmed.dropFirst()
                guard let close = firstUnquoted("]", in: header) else { continue }
                table = keyParts(header[..<close])
                if table.count >= 2, table[0] == "mcp_servers" { add(table[1]) }
                continue
            }
            guard let equals = firstUnquoted("=", in: trimmed[...]) else { continue }
            let key = keyParts(trimmed[..<equals])
            if table.isEmpty, key.count >= 2, key[0] == "mcp_servers" {
                add(key[1])
            } else if table == ["mcp_servers"], let name = key.first {
                add(name)
            }
        }
        return names
    }

    /// The names of the MCP servers in the `config.toml` at `path`, or nil
    /// when it can't be read. It's a small file in the home folder.
    public static func mcpServers(inFile path: String) -> [String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return mcpServers(in: text)
    }

    /// Where `character` first appears outside quotes, which is where a key
    /// ends.
    private static func firstUnquoted(_ character: Character, in text: Substring) -> Substring.Index? {
        var quote: Character?
        for index in text.indices {
            let current = text[index]
            if let open = quote {
                if current == open { quote = nil }
            } else if current == "\"" || current == "'" {
                quote = current
            } else if current == character {
                return index
            }
        }
        return nil
    }

    /// A TOML key's dotted parts, with the quotes taken off quoted ones.
    private static func keyParts(_ key: Substring) -> [String] {
        var parts: [String] = []
        var part = ""
        var quote: Character?
        for character in key {
            if let open = quote {
                if character == open { quote = nil } else { part.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(part.trimmingCharacters(in: .whitespaces))
                part = ""
            } else {
                part.append(character)
            }
        }
        parts.append(part.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static func isBareKey(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }
}
