// Command metadata drives both parsing and help. This module never opens Notes.
import Foundation

struct CLIOption {
    let name: String
    let value: String?
    let summary: String
    /// The one value a switch may carry: `--pinned`, `--pinned 1`, `--pinned=1`.
    var optionalValue: String? = nil

    init(_ name: String, _ value: String?, _ summary: String) {
        self.name = name
        self.value = value
        self.summary = summary
    }

    init(_ name: String, _ summary: String) {
        self.init(name, nil, summary)
    }

    init(_ name: String, optionalValue: String, _ summary: String) {
        self.init(name, "[\(optionalValue)]", summary)
        self.optionalValue = optionalValue
    }

    var usage: String { "--\(name)" + (value.map { " \($0)" } ?? "") }
}

struct Positional {
    let name: String
    let label: String
    let required: Bool

    /// `label` names the argument in errors, when `name` is too terse for that.
    init(_ name: String, label: String? = nil, required: Bool = true) {
        self.name = name
        self.label = label ?? name
        self.required = required
    }

    var usage: String { required ? "<\(name)>" : "[\(name)]" }

    static let note = Positional("note")
    static let item = Positional("item", required: false)
}

/// At least one of these arguments, named as a positional or an option, must be given.
struct Requirement {
    let anyOf: [String]
    let message: String
    let code: String

    init(_ anyOf: [String], _ message: String, code: String = "usage") {
        self.anyOf = anyOf
        self.message = message
        self.code = code
    }

    static let paragraph = Requirement(["item", "index"], "Name the paragraph by its text, or pass --index N.")
    static let style = Requirement(["style"], badStyleMessage, code: "bad_style")
    static var badStyleMessage: String { "Style must be one of: \(Style.names.keys.sorted().joined(separator: ", "))." }
}

struct CommandSpec {
    let name: String
    let positionals: [Positional]
    let summary: String
    let example: String
    var options: [CLIOption] = []
    var requires: [Requirement] = []
    var writes = false

    static let account = CLIOption("account", "NAME", "Select an account (writes default to On My Mac).")
    static let folder = CLIOption("folder", "PATH|ID", "Select a folder by path or id.")
    static let limit = CLIOption("limit", "N", "Maximum results: positive integer (default: 20).")
    static let index = CLIOption("index", "N", "Select a paragraph by its zero-based index.")
    static let undo = CLIOption("undo", "Undo the check or pin.")
    static let markdown = CLIOption("markdown", "FILE|-", "Read Markdown from a UTF-8 file or stdin (-).")
    static let placement = [CLIOption("after", "TEXT", "Insert after this paragraph's exact text."), index]
    static let globals = [CLIOption("help", "Show this help (-h); do no work."),
                          CLIOption("version", "Print the version as JSON; do no work.")]

    static let all: [CommandSpec] = [
        .init(name: "find", positionals: [Positional("text", required: false)], summary: "Find notes by title, newest modified first.",
              example: "find research --limit 5",
              options: [folder, account, CLIOption("tag", "TAG", "Filter by tag."),
                        CLIOption("pinned", optionalValue: "1", "Only pinned notes; accepts bare --pinned or legacy --pinned 1."), limit]),
        .init(name: "search", positionals: [Positional("query", label: "search query")], summary: "Search note bodies with matching snippets.",
              example: "search research --limit 5", options: [folder, account, limit]),
        .init(name: "read", positionals: [.note], summary: "Read a note and its paragraphs.",
              example: "read <note> --format markdown",
              options: [CLIOption("format", "json|markdown", "Output format (default: json).")]),
        .init(name: "backlinks", positionals: [.note], summary: "List links to a note or its paragraphs.",
              example: "backlinks <note>"),
        .init(name: "folders", positionals: [], summary: "List folder paths, ids and note counts.",
              example: "folders --account 'On My Mac'", options: [account]),
        .init(name: "tags", positionals: [], summary: "List tags and the number of notes using each.",
              example: "tags --account 'On My Mac'", options: [account]),
        .init(name: "create", positionals: [], summary: "Plan a new note from Markdown; its first line is the title.",
              example: "create --markdown note.md --folder Notes", options: [folder, account, markdown],
              requires: [Requirement(["markdown"], "Pass --markdown <file>, or --markdown - to read stdin.")], writes: true),
        .init(name: "append", positionals: [.note], summary: "Plan Markdown content to insert into a note.",
              example: "append <note> --markdown report.md", options: [markdown] + placement,
              requires: [Requirement(["markdown"], "Pass --markdown <file>, or --markdown - to read stdin.")], writes: true),
        .init(name: "create-folder", positionals: [Positional("name", label: "folder name")], summary: "Plan a folder or subfolder.",
              example: "create-folder Research --account 'On My Mac'",
              options: [account, CLIOption("parent", "PATH|ID", "Create inside this parent folder.")], writes: true),
        .init(name: "pin", positionals: [.note], summary: "Plan to pin or unpin a note.",
              example: "pin <note>", options: [undo], writes: true),
        .init(name: "set-style", positionals: [.note, .item, Positional("style", required: false)], summary: "Plan a paragraph style change, preserving its identity.",
              example: "set-style <note> --index 1 --style heading",
              options: [index, CLIOption("style", "STYLE", "title, heading, subheading, body, monospaced, bullet, dash, numbered, checklist."),
                        CLIOption("indent", "N", "Non-negative integer list indentation.")],
              requires: [.paragraph, .style], writes: true),
        .init(name: "format", positionals: [.note, .item], summary: "Plan character formatting in a paragraph.",
              example: "format <note> --index 1 --bold",
              options: [index, CLIOption("text", "SUBSTRING", "Format only the first occurrence of this text."),
                        CLIOption("bold", "Add bold."), CLIOption("italic", "Add italic."),
                        CLIOption("underline", "Add underline."), CLIOption("strike", "Add strikethrough."),
                        CLIOption("plain", "Remove formatting."),
                        CLIOption("highlight", "COLOR", "purple, pink, orange, mint, blue, none (or 0-5)."),
                        CLIOption("link", "URL", "Set a full web URL.")],
              requires: [.paragraph, Requirement(["bold", "italic", "underline", "strike", "highlight", "link", "plain"],
                                                 "Pass at least one of --bold --italic --underline --strike --highlight COLOR --link URL --plain.")],
              writes: true),
        .init(name: "check", positionals: [.note, .item], summary: "Plan to check or uncheck a checklist item.",
              example: "check <note> --index 1", options: [index, undo], requires: [.paragraph], writes: true),
        .init(name: "add-todo", positionals: [.note, Positional("text", label: "todo text")], summary: "Plan a native checklist item.",
              example: "add-todo <note> 'Review report'", options: placement, writes: true),
        .init(name: "add-tag", positionals: [.note, Positional("tag")], summary: "Plan a native tag.",
              example: "add-tag <note> research", options: placement, writes: true),
        .init(name: "link", positionals: [.note, Positional("target-note", label: "target note")], summary: "Plan a link to a note or one of its paragraphs.",
              example: "link <note> <target-note> --paragraph Summary",
              options: placement + [CLIOption("paragraph", "TEXT", "Target paragraph's exact text."),
                                    CLIOption("paragraph-index", "N", "Target paragraph's zero-based index.")], writes: true),
        .init(name: "add-table", positionals: [.note], summary: "Plan a native table from tab-separated UTF-8 text.",
              example: "add-table <note> --tsv table.tsv",
              options: placement + [CLIOption("tsv", "FILE|-", "Read rows from a file or stdin (-).")],
              requires: [Requirement(["tsv"], "Pass --tsv <file>, or --tsv - to read stdin. Rows are lines, cells are tab-separated.")], writes: true),
        .init(name: "add-url", positionals: [.note, Positional("url", label: "URL")], summary: "Plan a native link card.",
              example: "add-url <note> https://example.com", options: placement, writes: true),
        .init(name: "attach", positionals: [.note, Positional("file")], summary: "Plan a file attachment.",
              example: "attach <note> report.pdf", options: placement, writes: true),
        .init(name: "help", positionals: [Positional("command", required: false)], summary: "Show help without opening Notes.",
              example: "help read"),
        .init(name: "version", positionals: [], summary: "Print the version as JSON without opening Notes.",
              example: "version"),
    ]

    static let markdownSyntax = [
        "Markdown: # ## ### headings, paragraphs, - lists, 1. lists, - [ ] / - [x] to-dos, > quotes, ``` code,",
        "**bold** *italic* ~~strike~~ ==highlight== =={pink}highlight== [text](url), #tags,",
        "[[Note title]] and [[Note title#Paragraph]] links, | tables |, --- dividers,",
        "![](file) attachments, and a URL alone on a line as a link card.",
    ]

    static func named(_ name: String) -> CommandSpec {
        guard let spec = all.first(where: { $0.name == name }) else {
            fail("usage", "Unknown command \"\(name)\". Run `inknotes help`.")
        }
        return spec
    }

    /// Positionals, then any option that is required on its own.
    var usage: String {
        let requiredOptions = requires.compactMap { requirement -> String? in
            guard requirement.anyOf.count == 1, !positionals.contains(where: { $0.name == requirement.anyOf[0] }) else { return nil }
            return options.first { $0.name == requirement.anyOf[0] }?.usage
        }
        return (positionals.map(\.usage) + requiredOptions).joined(separator: " ")
    }

    /// Whether literal text can be passed, so `--` is worth mentioning.
    var takesText: Bool { !positionals.isEmpty && name != "help" }

    var acceptedOptions: [CLIOption] {
        options + (writes ? [CLIOption("apply", "Apply the plan; otherwise this is a dry run.")] : []) + Self.globals
    }

    var help: String {
        let invocation = ["inknotes", name, usage, "[options]"].filter { !$0.isEmpty }.joined(separator: " ")
        let optionLines = acceptedOptions.sorted { $0.name < $1.name }.map { "  \($0.usage)\n      \($0.summary)" }.joined(separator: "\n")
        var notes: [String] = []
        if positionals.contains(where: { $0.name == "note" }) { notes.append("<note> accepts a UUID, x-coredata:// URI, or numeric primary key.") }
        if options.contains(where: { $0.name == "index" }) { notes.append("Paragraph text must match exactly; --index selects a zero-based paragraph.") }
        if writes { notes.append("Writes are dry runs unless --apply is given. Writable accounts default to On My Mac.") }
        else if name == "read" { notes.append("Results are JSON by default; --format markdown prints Markdown.") }
        else if name == "help" { notes.append("Help is text and never opens Notes.") }
        else { notes.append("Results are JSON.") }
        if takesText { notes.append("If an argument starts with -, put -- before it. Everything after -- is literal.") }
        if ["create", "append"].contains(name) { notes += Self.markdownSyntax }
        return """
        Usage: \(invocation)
        \(summary)

        Options:
        \(optionLines)

        Example:
          inknotes \(example)

        Notes:
        \(notes.map { "  " + $0 }.joined(separator: "\n"))

        """
    }

    static var rootHelp: String {
        """
        Usage: inknotes <command> [arguments] [options]
        Read and edit Apple Notes natively.

        Commands:
        \(all.map { "  \($0.name) — \($0.summary)" }.joined(separator: "\n"))

        Options:
          -h, --help       Show help without opening Notes.
          --version        Print the version as JSON without opening Notes.

        Example:
          inknotes help read

        Notes:
          Run inknotes <command> --help for command options and an example.
          Results are JSON; read --format markdown prints Markdown.
          Writes are dry runs unless --apply is given.
          INKNOTES_WRITABLE_ACCOUNTS is comma-separated (default: On My Mac).
          Store commands need Full Disk Access. Help and version do not.
          Exit codes: 0 success, 2 usage or missing input, 1 operational failure.

        """
    }
}

/// Parsed arguments. `validate` runs before any command does, so handlers can rely on
/// required arguments being present and on `ints` holding the checked values.
struct Args {
    var command: String?
    var positional: [String] = []
    var options: [String: String] = [:]
    var ints: [String: Int] = [:]
    var helpRequested = false
    var apply: Bool { options["apply"] != nil }

    init(_ argv: [String]) {
        // Discovery takes precedence over validation, but never crosses --.
        let discovery = Array(argv.prefix { $0 != "--" })
        if discovery.contains("--help") || discovery.contains("-h") {
            helpRequested = true
            let path = discovery.filter { !$0.hasPrefix("-") }
            command = path.first == "help" && path.count > 1 ? path[1] : path.first
            if let command { _ = CommandSpec.named(command) }
            return
        }
        if discovery.contains("--version") { command = "version"; return }
        guard let first = argv.first else { helpRequested = true; return }
        command = first
        if first.hasPrefix("-") && first != "--" { fail("usage", "Unknown option \(first). Run `inknotes help`.") }
        let spec = CommandSpec.named(first)
        let hint = " Run `inknotes \(first) --help`."
        var parsingOptions = true
        var i = 1
        while i < argv.count {
            let token = argv[i]
            if parsingOptions && token == "--" { parsingOptions = false; i += 1; continue }
            if parsingOptions && token.hasPrefix("-") && token != "-" {
                let parts = token.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard token.hasPrefix("--"), let option = spec.acceptedOptions.first(where: { $0.name == parts[0] }) else {
                    let literal = spec.takesText ? " If it is text, put -- before it." : ""
                    fail("usage", "Unknown option \(token) for \(first).\(literal)\(hint)")
                }
                let inline = parts.count == 2 ? parts[1] : nil
                let value: String
                if let only = option.optionalValue {
                    if inline == nil && i + 1 < argv.count && argv[i + 1] == only { i += 1 }
                    value = inline ?? only
                    if value != only { fail("usage", "--\(option.name) accepts no value or \(only).\(hint)") }
                } else if option.value == nil {
                    if inline != nil { fail("usage", "--\(option.name) does not take a value.\(hint)") }
                    value = "1"
                } else if let inline {
                    value = inline
                } else {
                    guard i + 1 < argv.count, argv[i + 1] != "--" else { fail("usage", "--\(option.name) needs a value.\(hint)") }
                    if argv[i + 1].hasPrefix("--") {
                        fail("usage", "--\(option.name) needs a value; got the option \(argv[i + 1]). If that is the value, write --\(option.name)=\(argv[i + 1]).\(hint)")
                    }
                    i += 1
                    value = argv[i]
                }
                options[option.name] = value // Repeated options: last value wins.
            } else { positional.append(token) }
            i += 1
        }
        validate(spec, hint: hint)
        if first == "help" {
            helpRequested = true
            command = positional.first
            if let command { _ = CommandSpec.named(command) }
        }
    }

    private mutating func validate(_ spec: CommandSpec, hint: String) {
        if let missing = spec.positionals.dropFirst(positional.count).first(where: \.required) {
            fail("usage", "Missing \(missing.label).\(hint)")
        }
        if positional.count > spec.positionals.count {
            fail("usage", "Unexpected argument \"\(positional[spec.positionals.count])\" for \(spec.name).\(hint)")
        }
        for key in ["limit", "indent", "index", "paragraph-index"] {
            guard let value = options[key] else { continue }
            let minimum = key == "limit" ? 1 : 0
            guard let number = Int(value), number >= minimum else {
                fail(key.contains("index") ? "bad_index" : "usage", "--\(key) needs an integer >= \(minimum); got \"\(value)\".\(hint)")
            }
            ints[key] = number
        }
        if let format = options["format"], !["json", "markdown"].contains(format) {
            fail("usage", "--format must be json or markdown; got \"\(format)\".\(hint)")
        }
        for key in ["markdown", "tsv"] where options[key] == "" { fail("usage", "--\(key) needs a non-empty path.\(hint)") }
        if let value = options["highlight"] {
            let number = Highlight.value(value)
            if number < 0 { fail("bad_highlight", "--highlight takes purple, pink, orange, mint, blue, none or 0-5.\(hint)") }
            ints["highlight"] = number
        }
        if let link = options["link"], URL(string: link)?.scheme == nil { fail("bad_url", "--link needs a full URL.\(hint)") }
        if let style = argument("style", spec) {
            guard let number = Style.names[style.lowercased()] else { fail("bad_style", Requirement.badStyleMessage + hint) }
            ints["style"] = number
        }
        for requirement in spec.requires where !requirement.anyOf.contains(where: { argument($0, spec) != nil }) {
            fail(requirement.code, requirement.message + hint)
        }
    }

    /// An argument given as an option, or as the positional of that name.
    private func argument(_ name: String, _ spec: CommandSpec) -> String? {
        options[name] ?? spec.positionals.firstIndex { $0.name == name }.flatMap(positional)
    }

    func positional(_ i: Int) -> String? { positional.count > i ? positional[i] : nil }
}
