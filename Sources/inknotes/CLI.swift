// Command metadata drives both parsing and help. This module never opens Notes.
import Foundation

struct CLIOption {
    let name: String
    let value: String?
    let summary: String

    init(_ name: String, _ value: String?, _ summary: String) {
        self.name = name
        self.value = value
        self.summary = summary
    }

    init(_ name: String, _ summary: String) {
        self.init(name, nil, summary)
    }

    var usage: String { "--\(name)" + (value.map { " \($0)" } ?? "") }
}

struct CommandSpec {
    let name: String
    let usage: String
    let summary: String
    let example: String
    let minPositionals: Int
    let maxPositionals: Int
    var options: [CLIOption] = []
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
        .init(name: "find", usage: "[text]", summary: "Find notes by title, newest modified first.",
              example: "find research --limit 5", minPositionals: 0, maxPositionals: 1,
              options: [folder, account, CLIOption("tag", "TAG", "Filter by tag."),
                        CLIOption("pinned", "[1]", "Only pinned notes; accepts bare --pinned or legacy --pinned 1."), limit]),
        .init(name: "search", usage: "<query>", summary: "Search note bodies with matching snippets.",
              example: "search research --limit 5", minPositionals: 1, maxPositionals: 1, options: [folder, account, limit]),
        .init(name: "read", usage: "<note>", summary: "Read a note and its paragraphs.",
              example: "read <note> --format markdown", minPositionals: 1, maxPositionals: 1,
              options: [CLIOption("format", "json|markdown", "Output format (default: json).")]),
        .init(name: "backlinks", usage: "<note>", summary: "List links to a note or its paragraphs.",
              example: "backlinks <note>", minPositionals: 1, maxPositionals: 1),
        .init(name: "folders", usage: "", summary: "List folder paths, ids and note counts.",
              example: "folders --account 'On My Mac'", minPositionals: 0, maxPositionals: 0, options: [account]),
        .init(name: "tags", usage: "", summary: "List tags and the number of notes using each.",
              example: "tags --account 'On My Mac'", minPositionals: 0, maxPositionals: 0, options: [account]),
        .init(name: "create", usage: "[title]", summary: "Plan a new note from a title or Markdown.",
              example: "create 'Research' --folder Notes", minPositionals: 0, maxPositionals: 1,
              options: [folder, account, markdown, CLIOption("title", "TEXT", "Set the title instead of a positional title.")], writes: true),
        .init(name: "append", usage: "<note> --markdown FILE|-", summary: "Plan Markdown content to insert into a note.",
              example: "append <note> --markdown report.md", minPositionals: 1, maxPositionals: 1,
              options: [markdown] + placement, writes: true),
        .init(name: "create-folder", usage: "<name>", summary: "Plan a folder or subfolder.",
              example: "create-folder Research --account 'On My Mac'", minPositionals: 1, maxPositionals: 1,
              options: [account, CLIOption("parent", "PATH|ID", "Create inside this parent folder.")], writes: true),
        .init(name: "pin", usage: "<note>", summary: "Plan to pin or unpin a note.",
              example: "pin <note>", minPositionals: 1, maxPositionals: 1, options: [undo], writes: true),
        .init(name: "set-style", usage: "<note> [item] [style]", summary: "Plan a paragraph style change, preserving its identity.",
              example: "set-style <note> --index 1 --style heading", minPositionals: 1, maxPositionals: 3,
              options: [index, CLIOption("style", "STYLE", "title, heading, subheading, body, monospaced, bullet, dash, numbered, checklist."),
                        CLIOption("indent", "N", "Non-negative integer list indentation.")], writes: true),
        .init(name: "format", usage: "<note> [item]", summary: "Plan character formatting in a paragraph.",
              example: "format <note> --index 1 --bold", minPositionals: 1, maxPositionals: 2,
              options: [index, CLIOption("text", "SUBSTRING", "Format only the first occurrence of this text."),
                        CLIOption("bold", "Add bold."), CLIOption("italic", "Add italic."),
                        CLIOption("underline", "Add underline."), CLIOption("strike", "Add strikethrough."),
                        CLIOption("plain", "Remove formatting."),
                        CLIOption("highlight", "COLOR", "purple, pink, orange, mint, blue, none (or 0-5)."),
                        CLIOption("link", "URL", "Set a full web URL.")], writes: true),
        .init(name: "check", usage: "<note> [item]", summary: "Plan to check or uncheck a checklist item.",
              example: "check <note> --index 1", minPositionals: 1, maxPositionals: 2, options: [index, undo], writes: true),
        .init(name: "add-todo", usage: "<note> <text>", summary: "Plan a native checklist item.",
              example: "add-todo <note> 'Review report'", minPositionals: 2, maxPositionals: 2, options: placement, writes: true),
        .init(name: "add-tag", usage: "<note> <tag>", summary: "Plan a native tag.",
              example: "add-tag <note> research", minPositionals: 2, maxPositionals: 2, options: placement, writes: true),
        .init(name: "link", usage: "<note> <target-note>", summary: "Plan a link to a note or one of its paragraphs.",
              example: "link <note> <target-note> --paragraph Summary", minPositionals: 2, maxPositionals: 2,
              options: placement + [CLIOption("paragraph", "TEXT", "Target paragraph's exact text."),
                                    CLIOption("paragraph-index", "N", "Target paragraph's zero-based index.")], writes: true),
        .init(name: "add-table", usage: "<note> --tsv FILE|-", summary: "Plan a native table from tab-separated UTF-8 text.",
              example: "add-table <note> --tsv table.tsv", minPositionals: 1, maxPositionals: 1,
              options: placement + [CLIOption("tsv", "FILE|-", "Read rows from a file or stdin (-).")], writes: true),
        .init(name: "add-url", usage: "<note> <url>", summary: "Plan a native link card.",
              example: "add-url <note> https://example.com", minPositionals: 2, maxPositionals: 2, options: placement, writes: true),
        .init(name: "attach", usage: "<note> <file>", summary: "Plan a file attachment.",
              example: "attach <note> report.pdf", minPositionals: 2, maxPositionals: 2, options: placement, writes: true),
        .init(name: "draw", usage: "<note> --svg FILE", summary: "Plan a native, editable drawing from SVG.",
              example: "draw <note> --svg diagram.svg --width 400", minPositionals: 1, maxPositionals: 1,
              options: placement + [CLIOption("svg", "FILE", "Read SVG from a file."),
                                    CLIOption("width", "PT", "Finite positive width in points (default: 400)."),
                                    CLIOption("ink", "pen|pencil|marker", "Drawing ink (default: pen)."),
                                    CLIOption("color", "#rrggbb", "Override stroke color.")], writes: true),
        .init(name: "help", usage: "[command]", summary: "Show help without opening Notes.",
              example: "help read", minPositionals: 0, maxPositionals: 1),
        .init(name: "version", usage: "", summary: "Print the version as JSON without opening Notes.",
              example: "version", minPositionals: 0, maxPositionals: 0),
    ]

    static func named(_ name: String) -> CommandSpec {
        guard let spec = all.first(where: { $0.name == name }) else {
            fail("usage", "Unknown command \"\(name)\". Run `inknotes help`.")
        }
        return spec
    }

    var acceptedOptions: [CLIOption] {
        options + (writes ? [CLIOption("apply", "Apply the plan; otherwise this is a dry run.")] : []) + Self.globals
    }

    var help: String {
        let invocation = ["inknotes", name, usage, "[options]"].filter { !$0.isEmpty }.joined(separator: " ")
        let optionLines = acceptedOptions.sorted { $0.name < $1.name }.map { "  \($0.usage)\n      \($0.summary)" }.joined(separator: "\n")
        var notes: [String] = []
        if usage.contains("<note>") { notes.append("<note> accepts a UUID, x-coredata:// URI, or numeric primary key.") }
        if options.contains(where: { $0.name == "index" }) { notes.append("Paragraph text must match exactly; --index selects a zero-based paragraph.") }
        if writes { notes.append("Writes are dry runs unless --apply is given. Writable accounts default to On My Mac.") }
        else if name == "read" { notes.append("Results are JSON by default; --format markdown prints Markdown.") }
        else if name == "help" { notes.append("Help is text and never opens Notes.") }
        else { notes.append("Results are JSON.") }
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

struct Args {
    var command: String?
    var positional: [String] = []
    var options: [String: String] = [:]
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
        guard let first = argv.first else { return }
        command = first
        if first.hasPrefix("-") && first != "--" { fail("usage", "Unknown option \(first). Run `inknotes help`.") }
        let spec = CommandSpec.named(first)
        var parsingOptions = true
        var i = 1
        while i < argv.count {
            let token = argv[i]
            if parsingOptions && token == "--" { parsingOptions = false; i += 1; continue }
            if parsingOptions && token.hasPrefix("-") && token != "-" {
                let parts = token.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard token.hasPrefix("--"), let option = spec.acceptedOptions.first(where: { $0.name == parts[0] }) else {
                    fail("usage", "Unknown option \(token) for \(first). Run `inknotes \(first) --help`.")
                }
                let value: String
                if option.name == "pinned" {
                    if parts.count == 2 { value = parts[1] }
                    else if i + 1 < argv.count && argv[i + 1] == "1" { i += 1; value = "1" }
                    else { value = "1" }
                    if value != "1" { fail("usage", "--pinned accepts no value or 1. Run `inknotes find --help`.") }
                } else if option.value == nil {
                    if parts.count == 2 { fail("usage", "--\(option.name) does not take a value. Run `inknotes \(first) --help`.") }
                    value = "1"
                } else if parts.count == 2 {
                    value = parts[1]
                } else {
                    guard i + 1 < argv.count, argv[i + 1] != "--", !argv[i + 1].hasPrefix("--"), argv[i + 1] != "-h" else {
                        fail("usage", "--\(option.name) needs a value. Run `inknotes \(first) --help`.")
                    }
                    i += 1
                    value = argv[i]
                }
                options[option.name] = value // Repeated options: last value wins.
            } else { positional.append(token) }
            i += 1
        }
        validate(spec)
    }

    func validate(_ spec: CommandSpec) {
        let hint = " Run `inknotes \(spec.name) --help`."
        if positional.count < spec.minPositionals { fail("usage", "Missing input for \(spec.name)." + hint) }
        if positional.count > spec.maxPositionals { fail("usage", "Unexpected argument \"\(positional[spec.maxPositionals])\" for \(spec.name)." + hint) }
        for key in ["limit", "indent", "index", "paragraph-index"] {
            guard let value = options[key] else { continue }
            let minimum = key == "limit" ? 1 : 0
            if Int(value).map({ $0 >= minimum }) != true {
                fail(key.contains("index") ? "bad_index" : "usage", "--\(key) needs an integer >= \(minimum); got \"\(value)\"." + hint)
            }
        }
        if let width = options["width"], Double(width).map({ $0.isFinite && $0 > 0 }) != true {
            fail("usage", "--width needs a finite number > 0; got \"\(width)\"." + hint)
        }
        if let format = options["format"], !["json", "markdown"].contains(format) {
            fail("usage", "--format must be json or markdown; got \"\(format)\"." + hint)
        }
        if let ink = options["ink"], !["pen", "pencil", "marker"].contains(ink) { fail("usage", "--ink must be pen, pencil or marker." + hint) }
        for key in ["markdown", "svg", "tsv"] where options[key] == "" { fail("usage", "--\(key) needs a non-empty path." + hint) }
        for key in spec.name == "append" ? ["markdown"] : spec.name == "draw" ? ["svg"] : spec.name == "add-table" ? ["tsv"] : [] {
            if options[key] == nil { fail("usage", "Pass --\(key) FILE" + (key == "svg" ? "." : " or --\(key) - for stdin.") + hint) }
        }
        if ["check", "set-style", "format"].contains(spec.name) && positional.count < 2 && options["index"] == nil {
            fail("usage", "Name the paragraph by its text, or pass --index N." + hint)
        }
        if spec.name == "set-style" {
            guard let style = options["style"] ?? positional(2), Style.names[style.lowercased()] != nil else {
                fail("bad_style", "Style must be one of: \(Style.names.keys.sorted().joined(separator: ", "))." + hint)
            }
        }
        if spec.name == "format" && !["bold", "italic", "underline", "strike", "highlight", "link", "plain"].contains(where: { options[$0] != nil }) {
            fail("usage", "Pass at least one formatting option." + hint)
        }
        if let highlight = options["highlight"], Highlight.value(highlight) < 0 { fail("bad_highlight", "--highlight takes purple, pink, orange, mint, blue, none or 0-5." + hint) }
        if let link = options["link"], URL(string: link)?.scheme == nil { fail("bad_url", "--link needs a full URL." + hint) }
        if spec.name == "create" && positional.isEmpty && options["title"] == nil && options["markdown"] == nil {
            fail("usage", "Give the note a title or --markdown content." + hint)
        }
        if spec.name == "help", let target = positional(0) { _ = CommandSpec.named(target) }
    }

    func need(_ i: Int, _ what: String) -> String {
        guard let value = positional(i) else { fail("usage", "Missing \(what). Run `inknotes \(command ?? "help") --help`.") }
        return value
    }

    func positional(_ i: Int) -> String? { positional.count > i ? positional[i] : nil }
}
