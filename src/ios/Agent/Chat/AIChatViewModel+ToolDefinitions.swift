import Foundation

// MARK: - Tool Definitions (Canonical)

extension AIChatViewModel {

    /// [T-ios-vision-branch-mismatch #182] THE single source of truth for
    /// "can the model that will actually receive this turn see images itself".
    ///
    /// Both the `read_image` registration (which picks the tool DESCRIPTION) and
    /// its handler (which picks pixels-vs-Vision-Group) must agree, or the model
    /// is told one thing and handed another. They previously each wrote
    /// `selectedModel.capabilities.supportedModalities.contains(.imageInput)` —
    /// textually identical, yet wrong: `selectedModel` is the @Published UI
    /// property, while the REQUEST is built from `resolveCurrentEntry()` (see
    /// `activeModel` in runAgentLoop). With group routing or a session binding
    /// those are different models, so a text-only model could be registered with
    /// the Vision Group tool description and then served by the native pixel
    /// branch — returning metadata and no description at all.
    ///
    /// Resolve from the same entry the request uses, and fall back to
    /// `selectedModel` only when that resolution fails.
    var activeModelHasNativeVision: Bool {
        let model = resolveCurrentEntry()?.model ?? selectedModel
        return model.capabilities.supportedModalities.contains(.imageInput)
    }

    // MARK: - Tool Definitions (Canonical)

    func makeAgentTools() -> [AgentToolDefinition] {
        // [T-memory-toggle-gates-injection-and-tools-ios] memory_get and
        // memory_write are conditionally registered. When the per-session
        // toggle is off, drop both tool definitions so the LLM never sees
        // them. The system prompt also switches to a "memory disabled"
        // wording (see baseSystemPrompt below) so the model can correctly
        // tell the user to re-enable memory via /memory or Settings.
        let includeMemoryTools = memoryEnabled
        var tools: [AgentToolDefinition] = [
            AgentToolDefinition(
                name: "shell_execute",
                description: "Execute a command in an isolated Linux process (iSH/Alpine Linux). The command runs via /bin/sh -c with stdout and stderr captured separately via pipes. Each invocation spawns a fresh process — there is no shared terminal session. Default timeout is 15 minutes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Install Python data analysis packages', 'List files in home directory'). Use the same language as the user."),
                    "command": AgentToolParam(type: .string, description: "The shell command to execute. Supports multi-line commands directly — no special escaping needed. Keep under 1000 chars; for longer scripts, write to a file with file_write first, then run it."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default: 900). Use a larger value for long-running commands like package installs."),
                    "delay": AgentToolParam(type: .integer, description: "Delay in seconds before execution begins. The tool blocks the agent flow during this wait WITHOUT occupying the iSH shell, so other concurrent tasks can use it. Use this instead of sleep commands to avoid resource contention."),
                ],
                required: ["tool_title", "command"],
                propertyOrdering: ["tool_title", "command", "timeout", "delay"]
            ),
            AgentToolDefinition(
                name: "file_read",
                description: "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Read Python script contents', 'Check system configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to read (e.g. /var/minis/workspace/data.csv)"),
                    "offset": AgentToolParam(type: .integer, description: "1-based line number to start reading from (default: 1). Ignored when direction is 'tail'. If a previous read was truncated, its header ends with next_offset=N — pass that as offset to continue from where it stopped."),
                    "lines": AgentToolParam(type: .integer, description: "Maximum number of lines to return (default: all lines up to max_length)"),
                    "max_length": AgentToolParam(type: .integer, description: "Maximum character length of returned content (default: 15000)"),
                    "direction": AgentToolParam(type: .string, description: "Read direction: 'head' (from start, default) or 'tail' (from end of file)"),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "offset", "lines", "direction", "max_length"]
            ),
            AgentToolDefinition(
                name: "file_write",
                // [T-file-write-large-content-timeout] GH#223. Every byte of
                // `content` has to be GENERATED by the model as tool-call
                // arguments, streamed over the network, before the write even
                // starts. So a single 50-100KB write is a very long, fragile
                // request — the failures users report as "file_write timed out"
                // are the LLM request dying mid-generation, not the (purely
                // local, instant) filesystem write. Splitting into appends makes
                // each request short, and any part that can be COMPUTED rather
                // than transcribed should be, because generated bytes are the
                // actual cost. Without this guidance the model happily emits one
                // giant argument and the turn dies with no useful diagnostic.
                description: "Write content to a file on the Linux filesystem. Faster than shell_execute for writing files. Creates the file if it doesn't exist. Use append mode to add to existing files.\n\nIMPORTANT for large files (roughly >8KB): do NOT emit it as one call. Every byte of `content` is generated and streamed as tool arguments, so one huge call is slow and frequently dies mid-request. Instead either (a) write the first chunk, then extend it with further calls using append: true, or (b) when the content is repetitive or computable (SVG charts, generated tables, boilerplate), write a short script and run it with shell_execute — generating 2KB of code that emits 100KB beats transcribing 100KB.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Create Python statistics script', 'Write configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to write (e.g. /root/test.txt)"),
                    "content": AgentToolParam(type: .string, description: "The text content to write to the file. For large content prefer several appending calls over one huge one — see the tool description."),
                    "append": AgentToolParam(type: .boolean, description: "If true, append to existing file instead of overwriting (default: false)"),
                    "create_dirs": AgentToolParam(type: .boolean, description: "If true, create parent directories if they don't exist (default: false)"),
                ],
                required: ["tool_title", "path", "content"],
                propertyOrdering: ["tool_title", "path", "content", "append", "create_dirs"]
            ),
            AgentToolDefinition(
                name: "file_edit",
                description: "Make targeted edits to an existing file using exact string replacement. ALWAYS use file_read first to see the current file contents before editing. Prefer file_edit over file_write when modifying existing files — only the changed part needs to be specified. The old_string must match exactly one location in the file (including whitespace/indentation), unless replace_all is true.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Fix typo in Python script', 'Update config value'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to the file to edit (e.g. /root/script.py)"),
                    "old_string": AgentToolParam(type: .string, description: "The exact text to find in the file. Must match precisely including whitespace and indentation. Must be unique in the file unless replace_all is true."),
                    "new_string": AgentToolParam(type: .string, description: "The replacement text. Use empty string to delete old_string."),
                    "replace_all": AgentToolParam(type: .boolean, description: "If true, replace ALL occurrences of old_string (default: false)"),
                ],
                required: ["tool_title", "path", "old_string", "new_string"],
                propertyOrdering: ["tool_title", "path", "old_string", "new_string", "replace_all"]
            ),
            AgentToolDefinition(
                name: "browser_use",
                description: "Control a web browser with a few tabs (list_tabs shows the ones you may use). Do NOT use this tool for minis:// action URLs (open_terminal, views, settings) — those are app deep links, use Markdown links in chat instead. The browser supports both web URLs and minis:// resource URLs. Use minis:// URLs to preview session files (e.g. navigate to minis://workspace/index.html). Sub-resources (JS, CSS, images, fonts) referenced via minis:// absolute paths or relative paths within HTML pages resolve correctly. Use navigate to open URLs, screenshot to see the page (returns an image), click/type to interact with elements, get_text/get_readable to extract content, scroll to navigate long pages, scroll_and_collect to scroll through infinite-scroll/virtual-rendered pages (like Twitter/X timelines) and accumulate unique content items across scroll positions in a single call, find_elements to discover interactive elements, get_page_info for page metadata, get_backbone to get a structural overview of the page DOM as a simplified tree, fetch to download files/resources using the page's session (returns metadata and a minis:// URL), new_tab to open an additional tab, close_tab to close a tab, and list_tabs to see all open tabs. Use set_viewport with viewport_width + viewport_height to override the viewport for the current session (e.g. before screenshotting a 1920×1080 HTML composition that would otherwise be cropped to the phone viewport); pass reset=true to drop the session override and fall back to the global browser setting. Use get_cookies to retrieve cookies for the current page URL / current site root domain only (including HttpOnly cookies). get_cookies supports optional 'keyword' (filter by cookie name) and 'fuzzy' (true=contains match, false=exact match, default true). It returns only a summary and an offload env file path — raw cookie values are NOT included in the tool response. To reuse cookies in shell commands: `. /var/minis/offloads/env_cookies_xxx.sh && command`. You may define alias variables when needed. Use set_cookies to write cookies into the current page's cookie store via the native cookie store (so even HttpOnly cookies, which JS cannot set, land). Pass a 'cookies' array of objects, each with name + value (required) and optional domain (defaults to the current page host), path (defaults to '/'), secure, http_only, and expires (Unix timestamp in seconds; omit for a session cookie). Use wait_for_dom_stable to wait until the page DOM stops changing (useful after navigation or interactions that trigger async data loading — polls every 0.5s, resolves when mutation rate gradient is stable for 3+ intervals, default timeout 10s). Use tab_id to target a specific tab (defaults to the most recently used tab).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Open Wikipedia homepage', 'Take screenshot of current page'). Use the same language as the user."),
                    "action": AgentToolParam(type: .string, description: "The browser action to perform", enumValues: BrowserAction.allCases.map(\.rawValue)),
                    "url": AgentToolParam(type: .string, description: "URL to navigate to (for navigate action) or resource to download (for fetch action)"),
                    "selector": AgentToolParam(type: .string, description: "CSS selector for targeting elements (click, type, get_text, scroll, hover, find_elements). For scroll: specify a scrollable container to scroll (e.g. 'div.timeline'); if omitted, auto-detects the best scrollable element."),
                    "text": AgentToolParam(type: .string, description: "Text to type (for type action)"),
                    "coordinate_x": AgentToolParam(type: .integer, description: "X coordinate for click (alternative to selector)"),
                    "coordinate_y": AgentToolParam(type: .integer, description: "Y coordinate for click (alternative to selector)"),
                    "direction": AgentToolParam(type: .string, description: "Scroll direction", enumValues: ["up", "down"]),
                    "amount": AgentToolParam(type: .integer, description: "Scroll amount in pixels (default: 500)"),
                    "script": AgentToolParam(type: .string, description: "JavaScript code to execute (for execute_js action). The script runs inside an async function wrapper — `await` and top-level `return` are both supported (e.g. `var r = await fetch(url); return await r.json()`). DOM values may be returned directly — a DOMRect, Date, Error, element or NodeList is converted to plain JSON before it reaches you."),
                    "user_agent": AgentToolParam(type: .string, description: "User agent profile to switch to", enumValues: ["desktop_safari", "mobile_safari"]),
                    "max_depth": AgentToolParam(type: .integer, description: "Maximum tree depth for get_backbone (default: 5)"),
                    "scroll_count": AgentToolParam(type: .integer, description: "Number of scroll steps for scroll_and_collect (default: 10, max: 20). Each step scrolls by 'amount' pixels and waits for new content."),
                    "item_selector": AgentToolParam(type: .string, description: "CSS selector for individual content items in scroll_and_collect (e.g. 'article', '[data-testid=\"tweet\"]'). If omitted, auto-detects repeated elements."),
                    "tab_id": AgentToolParam(type: .integer, description: "Target tab ID (optional, defaults to your most recently used tab). Use list_tabs to see the tabs you may use; ids you did not receive from list_tabs/new_tab are rejected."),
                    "keywords": AgentToolParam(type: .string, description: "Filter cookies by name (for get_cookies). A space-separated string or array of strings. With fuzzy=true (default), ALL keywords must appear in the cookie name (case-insensitive). With fuzzy=false, cookie name must exactly equal any one of the provided keywords (case-insensitive). Omit to return all cookies for the current site."),
                    "fuzzy": AgentToolParam(type: .boolean, description: "Whether keyword matching is fuzzy (contains-all) or exact-any (for get_cookies, default: true)."),
                    "cookies": AgentToolParam(type: .string, description: "For set_cookies: a JSON array of cookie objects to write. Pass it as a JSON array (a JSON-encoded string of the array is also accepted). Each object: {\"name\": str (required), \"value\": str (required), \"domain\": str (optional, defaults to current page host), \"path\": str (optional, defaults to \"/\"), \"secure\": bool (optional), \"http_only\": bool (optional — sets an HttpOnly cookie that JS cannot read/set), \"expires\": int (optional, Unix timestamp in seconds; omit for a session cookie)}. Field-name variants from common cookie exports are accepted: httpOnly (=http_only), expirationDate (=expires), sameSite, and case/camel variants — so you can paste cookies verbatim from browser extensions (EditThisCookie / Cookie-Editor) or Playwright/Puppeteer storage."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds for wait_for_dom_stable (default: 10). The action polls every 0.5s and resolves when DOM mutation rate stabilizes."),
                    "viewport_width": AgentToolParam(type: .integer, description: "Viewport width in CSS pixels for set_viewport (e.g. 1920). Required together with viewport_height unless reset=true."),
                    "viewport_height": AgentToolParam(type: .integer, description: "Viewport height in CSS pixels for set_viewport (e.g. 1080). Required together with viewport_width unless reset=true."),
                    "reset": AgentToolParam(type: .boolean, description: "For set_viewport: when true, clear the session-level viewport override and fall back to the global browser setting."),
                    "full_page": AgentToolParam(type: .boolean, description: "For screenshot: capture the entire scrollable page by temporarily resizing the WebView to document.documentElement.scrollHeight. Default false captures viewport only. Capped at 32768px tall; when capped, result text includes 'Truncated: true' and the original height."),
                ],
                required: ["tool_title", "action"],
                propertyOrdering: ["tool_title", "action", "tab_id", "url", "selector", "text", "coordinate_x", "coordinate_y", "direction", "amount", "scroll_count", "item_selector", "script", "user_agent", "max_depth", "keywords", "fuzzy", "cookies", "timeout", "viewport_width", "viewport_height", "reset", "full_page"]
            ),
        ]

        if includeMemoryTools {
            tools.append(AgentToolDefinition(
                name: "memory_write",
                description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose. GLOBAL.md is read-only (user-maintained via Settings).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Save user preference for Python', 'Note today's project context'). Use the same language as the user."),
                    "content": AgentToolParam(type: .string, description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done/learned."),
                ],
                required: ["tool_title", "content"],
                propertyOrdering: ["tool_title", "content"]
            ))
            tools.append(AgentToolDefinition(
                name: "memory_get",
                description: "Retrieve memories from persistent storage. Supports keyword-based fuzzy search across memory files. Returns matching lines with surrounding context. Use this to recall previous knowledge, user preferences, or past notes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Recall user preferences', 'Search past notes'). Use the same language as the user."),
                    "scope": AgentToolParam(type: .string, description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"]),
                    "keywords": AgentToolParam(type: .string, description: "Space-separated keywords for fuzzy matching (e.g. 'python preference' or 'API key setup'). All keywords must appear in a line or its surrounding context for a match. Leave empty to return full memory files."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "scope", "keywords"]
            ))
        }

        // [T-r2-tool] 静态分析工具族：每个工具由「设置 → 逆向分析」里的
        // 对应开关独立控制。工具链是**内置**在 App 里的（随 rootfs 预装），
        // 开关只决定 AI 是否能看到该工具 —— 关闭时 AI 自然回落到原生
        // shell_execute（strings/hexdump）分析路径，零开销。
        //
        // 开关键名与 AnalysisCapability.defaultsKey 一致；radare2 沿用了历史键
        // "frida.deepAnalysis"（键名只是历史包袱，语义已是「深度分析引擎」）。
        if UserDefaults.standard.bool(forKey: "frida.deepAnalysis") {
            tools.append(AgentToolDefinition(
                name: "r2_execute",
                description: "Run radare2 (r2) commands against a binary file for static analysis. Executes `r2 -q -e scr.color=0 -e bin.relocs.apply=true -c \"<commands>\" <file>` and returns the text output. radare2 and the r2ghidra decompiler plugin are bundled in the app — no install step is needed.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'List functions in binary', 'Decompile function'). Use the same language as the user."),
                    "file": AgentToolParam(type: .string, description: "Linux path to the binary to analyze (e.g. /var/minis/shared/HexIpa.dylib or /var/minis/attachments/uploads/foo). If omitted, commands run without a file (r2 bare mode)."),
                    "commands": AgentToolParam(type: .string, description: "radare2 command string. Multiple commands separated by ';' (e.g. 'aaa; afl' or 'aaa; pdg @ sym.func'). Use 'aaa' first for full analysis, or 'aa' for faster partial analysis."),
                ],
                required: ["tool_title", "commands"],
                propertyOrdering: ["tool_title", "file", "commands"]
            ))
        }

        // capstone：指令级反汇编引擎（Python 绑定）。r2 适合「看整体」，
        // capstone 适合 AI 写脚本精确解析一段字节的指令流。
        if UserDefaults.standard.bool(forKey: "reverse.capstone") {
            tools.append(AgentToolDefinition(
                name: "capstone_disasm",
                description: "Disassemble raw machine code or a binary region using the capstone engine (Python binding). Use this when you need instruction-level detail for a specific byte range, rather than r2's whole-binary view. Runs a Python snippet in the sandbox.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                    "code": AgentToolParam(type: .string, description: "Python code using the `capstone` module. Must print results (e.g. `from capstone import *; md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); ...`). Available archs: CS_ARCH_ARM64, CS_ARCH_ARM, CS_ARCH_X86. Read bytes with open(path,'rb').read() or from a hex string."),
                ],
                required: ["tool_title", "code"],
                propertyOrdering: ["tool_title", "code"]
            ))
        }

        // binutils / file / sqlite：符号与结构层面的辅助查询。
        if UserDefaults.standard.bool(forKey: "reverse.binutils") {
            tools.append(AgentToolDefinition(
                name: "binutils_query",
                description: "Query binary symbols and structure with bundled binutils (nm, objdump, readelf, strings). Useful for symbol tables, section layout, linked libraries and embedded strings before deeper r2 analysis. Prefer this over plain shell commands when you want structured output.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                    "file": AgentToolParam(type: .string, description: "Linux path to the binary to inspect."),
                    "tool": AgentToolParam(type: .string, description: "Which binutils tool to run, plus optional flags (e.g. 'nm -u', 'objdump -h', 'readelf -d', 'strings -a'). Use short flags only.", enumValues: ["nm", "nm -u", "objdump -h", "objdump -t", "readelf -h", "readelf -d", "readelf -s", "strings -a"]),
                ],
                required: ["tool_title", "file", "tool"],
                propertyOrdering: ["tool_title", "file", "tool"]
            ))
        }

        if UserDefaults.standard.bool(forKey: "reverse.fileTools") {
            tools.append(AgentToolDefinition(
                name: "file_query",
                description: "Identify a file's real type and inspect its content with bundled `file` and `sqlite3`. Use it to confirm what a blob actually is (Mach-O slice, fat binary, plist, SQLite DB) and to explore SQLite databases found in a target app's data container.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                    "file": AgentToolParam(type: .string, description: "Linux path to the file to identify or open."),
                    "sql": AgentToolParam(type: .string, description: "Optional: SQL to run when the file is a SQLite database (e.g. '.tables' or 'SELECT * FROM sqlite_master'). Omit to just identify the file type."),
                ],
                required: ["tool_title", "file"],
                propertyOrdering: ["tool_title", "file", "sql"]
            ))
        }

        // [T-ios-vision-group #182] Expose read_image when the model can see
        // images ITSELF, or when a Vision Group is configured to see them on its
        // behalf. Previously a text-only model simply never got this tool, so an
        // image on disk was invisible to it with no recourse. The handler picks
        // the matching branch: native models get pixels, others get the Vision
        // Group's description as text.
        //
        // `isConfigured` is strict (group must resolve AND hold a usable
        // image-capable member), so we never advertise a tool whose non-native
        // path has nothing behind it.
        let nativeVision = activeModelHasNativeVision
        // Evaluate FIRST, not inside the `||` below: short-circuiting on
        // `nativeVision` would skip the call, and this read is also what keeps
        // `isConfiguredCached` — which the off-main T264 placeholder builder
        // relies on — up to date.
        let visionGroupConfigured = VisionGroupResolver.isConfigured
        if nativeVision || visionGroupConfigured {
            // Describe what this model will ACTUALLY receive. Promising "the
            // image is returned directly" to a text-only model would set up a
            // false expectation and invite it to re-call the tool when no pixels
            // arrive; the non-native branch returns a written description instead.
            let readImageDescription = nativeVision
                ? "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size)."
                : "Read an image file from the Linux filesystem and return a written description of it. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, user-attached photos, or any visual output. You cannot see images directly, so the image is analyzed by a separate vision model and you receive its detailed description plus a transcription of any visible text, along with metadata (dimensions, file size). Because you cannot look again yourself, use the optional 'prompt' argument to ask for exactly what you need from the image — that is your only way to follow up on specific details."
            // [T-ios-vision-group-t264 #182] The `prompt` argument is what makes
            // the non-native branch usable for anything but a generic caption:
            // the host model can't look at the image, so this is its only lever
            // for directing the describing model. On the native branch the model
            // sees the pixels itself, so the argument is documented as optional
            // context rather than a question.
            let promptDescription = nativeVision
                ? "Optional. A note about what you are looking for in the image. Recorded alongside the result; the image itself is returned to you in full either way."
                : "Optional. A specific question or instruction about the image, e.g. 'transcribe the table', 'what error message is shown in this screenshot', 'describe the people and their expressions'. This is passed to the vision model that reads the image for you, so ask for exactly the detail you need. If omitted, a generic detailed description with full text transcription is returned."
            tools.append(AgentToolDefinition(
                name: "read_image",
                description: readImageDescription,
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'View generated bar chart', 'Inspect downloaded screenshot'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis:// URL (e.g. minis://attachments/chart.png)"),
                    "prompt": AgentToolParam(type: .string, description: promptDescription),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "prompt"]
            ))
        }

        // [T-tools-granular-switches] Settings › Tools › Browser Use off ⇒
        // browser_use is not in the schema at all (it is declared in the base
        // list above so its position is unchanged when on). A helper inherits
        // the same switch: delegation itself passed its own gate, but the
        // switch can flip mid-run and the child's next turn must honour it.
        if !Self.toolEnabled(.browser) {
            tools.removeAll { $0.name == "browser_use" }
        }

        // [T-p1-delegate-task] Depth = 1: a helper never sees this tool.
        // [T-tools-granular-switches] Settings › Tools › Agents removes it
        // globally (agent_status rides with it — pointless without
        // delegate_task).
        if !isHelper && Self.toolEnabled(.agents) {
            tools.append(AgentToolDefinition(
                name: SubAgentDefinition.toolName,
                description: "Delegate a self-contained task to a sub agent — its own isolated context and tool loop, in a hidden child session running concurrently with you — and inspect or stop the ones you started. `action` defaults to `delegate`.\n\nDELEGATE work needing many rounds of exploration (reading lots of files or pages, trial-and-error), producing bulk output you only need a conclusion from, or splitting into independent sub-problems you can run in parallel (several calls in one turn). DO NOT delegate what you can finish in one or two tool calls, what needs the user's confirmation mid-way, or work depending on nuances of this conversation you cannot restate. A sub agent cannot see this conversation and has no memory: write `task` as a complete brief for a capable colleague who just walked in — goal, constraints, where things are, what exactly to return. It costs a full model run, so nothing trivial. Only 3 run at once, but delegate everything you need anyway: extras return status=queued and start as slots free, so never re-delegate a queued task or wait for a slot.\n\nwait=false (default) returns at once with status=running and a job_id; the result arrives later as a NEW MESSAGE prefixed [Background task finished …] (also on cancel/timeout/failure). End your turn when you have nothing else to do — never poll in a loop, never promise to report back. You do NOT need action=status to receive results.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user on the block in the tool bar and in the transcript (e.g. 'Survey repo test layout', 'Check on the research agent'). Use the same language as the user."),
                    "action": AgentToolParam(type: .string, description: "\"delegate\" (default): start a sub agent on `task`. \"status\": report this conversation's sub agents — state (queued/running/done/cancelled/failed/interrupted), current tool, elapsed, model, finished results; `job_id` for one, omit for all. \"steer\": course-correct a RUNNING one without stopping it (see `message`). \"cancel\": stop the one named by `job_id`; its partial result is still posted back. \"resume\": restart runs the app lost when it was killed (they report `interrupted`); `job_id`/`child_session_id` for one, omit both for all.", enumValues: ["delegate", "status", "steer", "cancel", "resume"]),
                    "task": AgentToolParam(type: .string, description: "action=delegate only, required. The complete, self-contained brief: goal, success criteria, relevant paths/URLs, constraints, and exactly what to return. The sub agent sees nothing else."),
                    // [T-sub-agents-v1] enumValues are the enabled sub agent
                    // names, rebuilt every turn (the schema is not cached), so a
                    // rename takes effect on the next request and the model
                    // cannot invent a name.
                    "agent": AgentToolParam(type: .string, description: "action=delegate only. Which sub agent runs this task. Pick the one whose description matches the work; omit it to use the general one.", enumValues: SubAgentStore.shared.subAgents.map(\.name)),
                    "model_choice": AgentToolParam(type: .string, description: "action=delegate only, and only when the chosen sub agent is set to Auto — one the user pinned to a group ignores it. DEFAULT TO \"same_as_me\". The user picked the model this conversation runs on, and that choice covers the work you delegate from it: a sub agent on a different model can cost far more, or be far weaker, than what they chose, and they never see it happen. Only depart from it when the task itself gives you a specific reason, judged by what the task demands and not by how long it will take. \"same_as_me\" (default): this conversation's model — anything continuing the work at hand, and every case where you are unsure. \"default_model\": the user's strongest group — only when this task clearly needs more capability than the current model, e.g. multi-step reasoning, design judgment, ambiguous requirements where a wrong answer is expensive. \"sub_model\": the user's light group — only when the task is clearly mechanical and well-bounded, verifiable at a glance (collecting files against a list, format conversion, fixed commands, lookups).", enumValues: ["same_as_me", "default_model", "sub_model"]),
                    "context": AgentToolParam(type: .string, description: "action=delegate only. Optional raw material to hand over verbatim (file excerpts, error output, a list of paths). Appended to the task."),
                    "max_minutes": AgentToolParam(type: .integer, description: "action=delegate only. Wall-clock budget in minutes (default 10, maximum 60). The sub agent is stopped when it runs out and whatever it produced so far is returned with status=timeout."),
                    "wait": AgentToolParam(type: .boolean, description: "action=delegate only. false (default): return at once with status=running; the result is posted here as a new message when done. true: block until it finishes and return the result here — only when the next step cannot proceed without it. If the user sends a message while you wait, the run moves to the background and the call returns status=running."),
                    "progress_report": AgentToolParam(type: .string, description: "action=delegate only. Mid-run [Background task progress …] messages (status, current tool, elapsed, latest message). \"none\" (default): final result only. \"frequent\": every 15s when something changed. \"moderate\": once a minute. Each costs you a turn — leave at none unless the user asked to follow along or you must react mid-way. Answer one with at most a short sentence, or just carry on; never re-delegate or poll because of one. Ignored when wait=true.", enumValues: ["none", "frequent", "moderate"]),
                    "child_session_id": AgentToolParam(type: .string, description: "action=resume only, optional. The child_session_id of one interrupted sub agent to restart. Omit to resume every interrupted sub agent in this conversation."),
                    "job_id": AgentToolParam(type: .string, description: "action=status/steer/cancel. The job_id this tool returned when it started the sub agent (a prefix is accepted). Required for steer and cancel; omit on status to list every sub agent of this conversation."),
                    "message": AgentToolParam(type: .string, description: "action=steer only, required. The correction, phrased as an instruction to the running sub agent (e.g. 'focus on pricing, skip the migration notes'). Use when new information changes what it should do — it keeps the work already done, unlike cancelling and re-delegating. Read at its next turn, so a running tool call is not interrupted; if the run finishes first the result reports the steer as missed."),
                ],
                // `task` is NOT required at the schema level: it is required for
                // action=delegate and meaningless for status/cancel, which JSON
                // Schema cannot express here. The dispatcher rejects a delegate
                // call with no task.
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "action", "task", "agent", "model_choice", "context", "max_minutes", "wait", "progress_report", "job_id", "message", "child_session_id"]
            ))
        }
        // ── GitHub 工具 ──
        //
        // 用户在「设置 → GitHub 连接」填入个人访问令牌后，AI 即可直接操作
        // 仓库、文件、提交、Issue/PR 与搜索。令牌存 Keychain，AI 无需再索取。
        tools.append(AgentToolDefinition(
            name: "github",
            description: "直接操作 GitHub：查看/创建仓库、读写文件并提交、管理分支、处理 Issue 与 PR、搜索。需要用户先在「设置 → GitHub 连接」填写个人访问令牌；未连接时返回提示。所有操作以用户账号身份执行，权限范围取决于令牌。",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                "action": AgentToolParam(type: .string, description: "要执行的操作。whoami（当前账号）/ list_repos / get_repo / list_files / read_file / write_file / delete_file / list_commits / create_branch / list_issues / create_issue / comment_issue / search / api（直接调用任意 API 路径）。", enumValues: ["whoami","list_repos","get_repo","list_files","read_file","write_file","delete_file","list_commits","create_branch","list_issues","create_issue","comment_issue","search","api"]),
                "repo": AgentToolParam(type: .string, description: "仓库全名，格式 owner/name，如 'hkyttkx/OpenMinis'。除 whoami / list_repos / search / api 外都要填。"),
                "path": AgentToolParam(type: .string, description: "文件或目录路径（list_files / read_file / write_file / delete_file 用）；api 动作时填 API 路径（如 /repos/owner/name）。"),
                "content": AgentToolParam(type: .string, description: "文件内容（write_file 必填）。"),
                "message": AgentToolParam(type: .string, description: "提交信息（write_file / delete_file 可选）。"),
                "branch": AgentToolParam(type: .string, description: "分支名（write_file / delete_file / list_commits / create_branch 用）。create_branch 时是新建的分支名。"),
                "ref": AgentToolParam(type: .string, description: "读取文件或列目录时的 ref（分支/tag/commit，可选）。"),
                "from": AgentToolParam(type: .string, description: "create_branch 的源分支，默认 main。"),
                "title": AgentToolParam(type: .string, description: "Issue 标题（create_issue 必填）。"),
                "body": AgentToolParam(type: .string, description: "Issue 正文或评论内容（create_issue / comment_issue）；api 动作时作为 JSON 请求体。"),
                "number": AgentToolParam(type: .integer, description: "Issue / PR 编号（comment_issue 必填）。"),
                "query": AgentToolParam(type: .string, description: "搜索关键词（search 必填）。"),
                "kind": AgentToolParam(type: .string, description: "搜索类型（search 用），默认 repositories。", enumValues: ["repositories","code","issues","commits","users"]),
                "state": AgentToolParam(type: .string, description: "Issue 状态筛选（list_issues 用），默认 open。", enumValues: ["open","closed","all"]),
                "limit": AgentToolParam(type: .integer, description: "返回条数上限，默认 20-30。"),
                "owner": AgentToolParam(type: .string, description: "list_repos 时可指定用户名，默认当前登录账号。"),
                "method": AgentToolParam(type: .string, description: "api 动作的 HTTP 方法，默认 GET。", enumValues: ["GET","POST","PATCH","PUT","DELETE"]),
            ],
            required: ["tool_title", "action"],
            propertyOrdering: ["tool_title","action","repo","path","content","message","branch","ref","from","title","body","number","query","kind","state","limit","owner","method"]
        ))

        // ── 宿主文件访问工具 ──
        //
        // 让 AI 在静态分析时直接读取手机上的原始文件，而不必先让用户
        // 手动把文件复制到沙盒。访问级别由用户在设置里选择：
        // 关闭 / 询问后访问（弹窗确认）/ 全自动访问。
        tools.append(AgentToolDefinition(
            name: "host_access",
            description: "申请或查询宿主文件系统访问权限。iSH 沙盒只能看到经挂载的路径，本工具把宿主目录只读挂载进沙盒，使 r2 / binutils / file / strings / sqlite3 能直接读取手机上的原始文件（已安装 App 的二进制、数据容器、越狱目录等）。action=list 查看当前可用位置与状态；action=request 申请访问某个位置（在「询问后访问」模式下会向用户弹窗确认）。挂载后通过 /var/minis/host/<短名>/... 访问对应宿主目录。",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                "action": AgentToolParam(type: .string, description: "'list' 查看可用位置与当前状态；'request' 申请访问某个位置。默认 list。", enumValues: ["list", "request"]),
                "location": AgentToolParam(type: .string, description: "位置短名：apps（已安装 App 的包）/ containers（App 数据容器）/ shared（App Group 共享目录）/ jb（越狱根）/ root（整个文件系统）。与 path 二选一。", enumValues: ["apps", "containers", "shared", "jb", "root"]),
                "path": AgentToolParam(type: .string, description: "自定义宿主绝对路径，如 /var/mobile/Library。与 location 二选一。"),
            ],
            required: ["tool_title", "action"],
            propertyOrdering: ["tool_title", "action", "location", "path"]
        ))

        // ── 动态注入工具组 ──
        //
        // 与静态分析工具不同，这两个工具会真实修改目标 App 的运行状态，
        // 因此仅当用户从注入面板发起（或明确要求）时才应在会话中出现。
        // 这里做无条件注册，由模型在合适的上下文里自行调用 —— 注入前的
        // 「是否确认」由模型与用户对话确认，工具本身只负责执行。
        tools.append(AgentToolDefinition(
            name: "hook_compile",
            description: "把一组 Hook 配置编译成可注入的 dylib。实现方式是基于 App 内置的 FuckEngine 通用引擎模板，把 Hook 配置以 JSON 形式原地写入 dylib 的 __DATA,__fuckeng_hk section（模板预留 64KB，无需编译器）。产出物保存在 App 的动态库目录，可直接交给 dylib_inject 使用。调用前请先与用户确认 Hook 方案。",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                "hooks": AgentToolParam(type: .string, description: "JSON array string of hook objects. Each object: {\"className\": \"SomeClass\", \"methodName\": \"someMethod\", \"isClassMethod\": false, \"hookType\": \"logMethod\"|\"returnConstant\"|\"blockMethod\"|\"modifyProperty\"|\"flexOverride\"|\"methodSwizzle\", optional \"returnValue\": \"1\", optional \"property\": \"someProp\"}. Example: '[{\"className\":\"LoginVC\",\"methodName\":\"verifyToken\",\"hookType\":\"returnConstant\",\"returnValue\":\"1\"}]'"),
                "name": AgentToolParam(type: .string, description: "Output dylib base name (no extension), e.g. 'MyHook'. Only letters, digits, underscore and hyphen are kept."),
                "hook_delay": AgentToolParam(type: .integer, description: "Seconds to wait after the engine loads before applying hooks. Default 3. Increase for apps with slow startup."),
            ],
            required: ["tool_title", "hooks", "name"],
            propertyOrdering: ["tool_title", "hooks", "name", "hook_delay"]
        ))

        tools.append(AgentToolDefinition(
            name: "dylib_inject",
            description: "把一个 dylib 注入到运行中的目标 App 进程。这是运行时可逆操作，目标 App 重启后注入失效。注入前务必先与用户确认目标 App 与注入模式。执行结果与失败原因会返回，完整过程记录在 App 的注入日志里。",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user. Use the same language as the user."),
                "bundle_id": AgentToolParam(type: .string, description: "Target app bundle identifier, e.g. 'com.example.app'. Must be an installed app."),
                "dylib_path": AgentToolParam(type: .string, description: "Absolute path to the dylib to inject. Usually the output path returned by hook_compile."),
                "mode": AgentToolParam(type: .string, description: "'clean' (default) keeps the dylib only in the app's temp directory and never writes into the target app bundle — recommended. 'strict' copies the dylib next to the target app bundle first, which is more compatible with older setups; both clean up afterwards.", enumValues: ["clean", "strict"]),
            ],
            required: ["tool_title", "bundle_id", "dylib_path"],
            propertyOrdering: ["tool_title", "bundle_id", "dylib_path", "mode"]
        ))
        return tools
    }

}

// MARK: - Sub agent roster  [T-sub-agents-v1]

extension AIChatViewModel {

    /// The "which sub agent for which job" section of the system prompt.
    ///
    /// Built from the same roster the `agent` parameter's enumValues come from,
    /// so a name can never be advertised in one and rejected by the other. The
    /// per-line Model note tells the model where each agent runs, which is
    /// information only (the model does not choose it) but explains why two
    /// agents can behave differently on the same task.
    ///
    /// Cost is bounded by SubAgentLimits (10 × (40 + 200) chars, ~800 tokens at
    /// the maximum), with a defensive prefix(200) here in case a definition
    /// reached storage through some path that skipped the clamp.
    @MainActor
    static func subAgentRosterSection() -> String {
        let roster = SubAgentStore.shared.subAgents
        guard !roster.isEmpty else { return "" }
        let store = ProviderConfigStore.shared
        var lines = ["Available sub agents (pass the name as \(SubAgentDefinition.toolName).agent):"]
        for def in roster {
            let desc = String(def.description.prefix(SubAgentLimits.descriptionMaxLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model: String
            if let gid = def.modelGroupId, let group = store.group(for: gid) {
                // Pinned by the user: model_choice does not apply to this one.
                model = "fixed — \(group.name)"
            } else {
                model = "Auto — you choose with model_choice"
            }
            lines.append("- \(def.name) — \(desc) Model: \(model).")
        }
        lines.append("Prefer a specific sub agent when its description matches; otherwise use the general one.")
        return lines.joined(separator: "\n") + "\n"
    }
}
