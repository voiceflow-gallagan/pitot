import Foundation

@testable import PitotCore

/// A hand-written catalog shaped like the real `Catalog/tweaks.json`, plus builders for one-off rows.
enum CatalogSamples {
    static let json = #"""
        {
          "researchDate": "2026-10-05",
          "claudeCodeVersionChecked": "2.1.291",
          "tweaks": [
            {
              "id": "viewMode",
              "location": { "type": "setting", "path": ["viewMode"] },
              "valueType": {
                "type": "enum",
                "options": [
                  { "value": "default", "label": "Default" },
                  { "value": "verbose", "label": "Verbose" },
                  { "value": "focus", "label": "Focus" }
                ]
              },
              "defaultDescription": "Unset: the verbose setting and your last /focus choice apply.",
              "title": "Starting view",
              "description": "The transcript view new sessions start in.",
              "category": "Interface",
              "risks": [],
              "status": "documented",
              "requires": [
                {
                  "tweakId": "tui",
                  "when": "focus",
                  "equals": "fullscreen",
                  "behavior": "autoSet",
                  "reason": "Focus view needs the fullscreen renderer."
                }
              ],
              "docURL": "https://code.claude.com/docs/en/settings-reference#viewmode"
            },
            {
              "id": "tui",
              "location": { "type": "setting", "path": ["tui"] },
              "valueType": {
                "type": "enum",
                "options": [
                  { "value": "default", "label": "Classic" },
                  { "value": "fullscreen", "label": "Fullscreen" }
                ]
              },
              "defaultDescription": "Unset: Claude Code picks the renderer.",
              "title": "Renderer",
              "description": "The classic renderer or the flicker-free fullscreen one.",
              "category": "Interface",
              "risks": [],
              "status": "documented",
              "overriddenBy": [
                { "envName": "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN" },
                { "envName": "CLAUDE_CODE_NO_FLICKER" }
              ],
              "docURL": "https://code.claude.com/docs/en/settings-reference#tui"
            },
            {
              "id": "noFlicker",
              "location": { "type": "env", "name": "CLAUDE_CODE_NO_FLICKER" },
              "valueType": { "type": "bool" },
              "defaultDescription": "Unset: the tui setting decides.",
              "title": "Fullscreen renderer (env)",
              "description": "1 forces fullscreen, 0 forces classic.",
              "category": "Interface",
              "risks": [],
              "status": "documented",
              "docURL": "https://code.claude.com/docs/en/env-vars#variables"
            },
            {
              "id": "sandbox.enabled",
              "location": { "type": "setting", "path": ["sandbox", "enabled"] },
              "valueType": { "type": "bool" },
              "defaultDescription": "false",
              "defaultValue": false,
              "title": "Sandbox shell commands",
              "description": "Run Bash commands inside the sandbox.",
              "category": "Safety",
              "risks": ["security"],
              "status": "documented",
              "confirm": {
                "message": "With the sandbox off, shell commands can read your files and reach any host.",
                "appliesWhen": { "type": "onDisable" }
              },
              "docURL": "https://code.claude.com/docs/en/settings-reference#sandbox-enabled"
            },
            {
              "id": "sandbox.failIfUnavailable",
              "location": { "type": "setting", "path": ["sandbox", "failIfUnavailable"] },
              "valueType": { "type": "bool" },
              "defaultDescription": "false",
              "title": "Stop if the sandbox cannot start",
              "description": "Exit at startup instead of running commands unsandboxed.",
              "category": "Safety",
              "risks": ["security"],
              "status": "documented",
              "requires": [
                { "tweakId": "sandbox.enabled", "equals": true, "behavior": "disable", "reason": "Only matters while the sandbox is on." }
              ],
              "docURL": "https://code.claude.com/docs/en/settings-reference#sandbox-failifunavailable"
            },
            {
              "id": "sandbox.autoAllowBashIfSandboxed",
              "location": { "type": "setting", "path": ["sandbox", "autoAllowBashIfSandboxed"] },
              "valueType": { "type": "bool" },
              "defaultDescription": "true",
              "title": "Run sandboxed commands without asking",
              "description": "Sandboxed Bash runs without a permission prompt.",
              "category": "Safety",
              "risks": ["security"],
              "status": "documented",
              "requires": [
                { "tweakId": "sandbox.enabled", "equals": true, "behavior": "disable", "reason": "Only matters while the sandbox is on." }
              ],
              "docURL": "https://code.claude.com/docs/en/settings-reference#sandbox-autoallowbashifsandboxed"
            },
            {
              "id": "subagentModel",
              "location": { "type": "env", "name": "CLAUDE_CODE_SUBAGENT_MODEL" },
              "valueType": { "type": "string" },
              "defaultDescription": "Unset: subagents use their own default.",
              "title": "Subagent model",
              "description": "Default model for subagents.",
              "category": "Model",
              "risks": ["cost"],
              "status": "documented",
              "docURL": "https://code.claude.com/docs/en/env-vars#variables"
            },
            {
              "id": "subagentModelForce",
              "location": { "type": "env", "name": "CLAUDE_CODE_SUBAGENT_MODEL_FORCE" },
              "valueType": { "type": "flag" },
              "defaultDescription": "Unset: agents may pick their own model.",
              "title": "Force the subagent model",
              "description": "Use one model for every subagent. Works without a subagent model too.",
              "category": "Model",
              "risks": ["cost"],
              "status": "documented",
              "minVersion": "2.1.257",
              "docURL": "https://code.claude.com/docs/en/env-vars#variables"
            },
            {
              "id": "model",
              "location": { "type": "setting", "path": ["model"] },
              "valueType": { "type": "string" },
              "defaultDescription": "Unset: your account's default model.",
              "title": "Model",
              "description": "Default model for new sessions.",
              "category": "Model",
              "risks": ["cost"],
              "status": "documented",
              "suggestions": [
                { "value": "opus", "label": "Opus", "note": "Latest Opus." },
                { "value": "opusplan", "label": "Opus plan", "note": "Opus in plan mode, Sonnet otherwise." },
                { "value": "sonnet", "label": "Sonnet" }
              ],
              "overriddenBy": [{ "envName": "ANTHROPIC_MODEL" }],
              "docURL": "https://code.claude.com/docs/en/settings-reference#model"
            },
            {
              "id": "effortLevel",
              "location": { "type": "setting", "path": ["effortLevel"] },
              "valueType": {
                "type": "enum",
                "options": [
                  { "value": "low", "label": "Low" },
                  { "value": "medium", "label": "Medium" },
                  { "value": "high", "label": "High" }
                ]
              },
              "defaultDescription": "Unset",
              "title": "Effort",
              "description": "Default reasoning effort.",
              "category": "Model",
              "risks": ["cost"],
              "status": "documented",
              "overriddenBy": [{ "envName": "CLAUDE_CODE_EFFORT_LEVEL" }],
              "docURL": "https://code.claude.com/docs/en/settings-reference#effortlevel"
            },
            {
              "id": "disableClaudeAiConnectors",
              "location": { "type": "setting", "path": ["disableClaudeAiConnectors"] },
              "valueType": { "type": "bool" },
              "defaultDescription": "false",
              "title": "Skip claude.ai connectors",
              "description": "Stop fetching your claude.ai MCP connectors.",
              "category": "MCP",
              "risks": ["behavior"],
              "status": "documented",
              "overriddenBy": [{ "envName": "ENABLE_CLAUDEAI_MCP_SERVERS", "whenValue": "false" }],
              "docURL": "https://code.claude.com/docs/en/settings-reference#disableclaudeaiconnectors"
            },
            {
              "id": "disableTelemetry",
              "location": { "type": "env", "name": "DISABLE_TELEMETRY" },
              "valueType": { "type": "flag" },
              "defaultDescription": "Unset: telemetry is on.",
              "title": "Turn off telemetry",
              "description": "Opt out of usage telemetry.",
              "category": "Privacy",
              "risks": ["privacy"],
              "status": "documented",
              "docURL": "https://code.claude.com/docs/en/env-vars#variables"
            },
            {
              "id": "askUserQuestionTimeout",
              "location": { "type": "setting", "path": ["askUserQuestionTimeout"] },
              "valueType": {
                "type": "enum",
                "options": [
                  { "value": "60s", "label": "1 minute" },
                  { "value": "5m", "label": "5 minutes" },
                  { "value": "10m", "label": "10 minutes" },
                  { "value": "never", "label": "Never" }
                ]
              },
              "defaultDescription": "never",
              "title": "Question timeout",
              "description": "Continue on its own when a question waits this long.",
              "category": "Interface",
              "risks": ["behavior"],
              "status": "documented",
              "scope": "userOnly",
              "docURL": "https://code.claude.com/docs/en/settings-reference#askuserquestiontimeout"
            },
            {
              "id": "cleanupPeriodDays",
              "location": { "type": "setting", "path": ["cleanupPeriodDays"] },
              "valueType": { "type": "integer", "min": 1 },
              "defaultDescription": "30",
              "title": "Keep transcripts for",
              "description": "Days before old transcripts are deleted.",
              "category": "Privacy",
              "risks": ["behavior"],
              "status": "documented",
              "docURL": "https://code.claude.com/docs/en/settings-reference#cleanupperioddays"
            },
            {
              "id": "plansDirectory",
              "location": { "type": "setting", "path": ["plansDirectory"] },
              "valueType": { "type": "path" },
              "defaultDescription": "~/.claude/plans",
              "title": "Plans folder",
              "description": "Where plan-mode files are written.",
              "category": "Memory",
              "risks": [],
              "status": "documented",
              "docURL": "https://code.claude.com/docs/en/settings-reference#plansdirectory"
            },
            {
              "id": "anthropicBaseURL",
              "location": { "type": "env", "name": "ANTHROPIC_BASE_URL" },
              "valueType": { "type": "string" },
              "defaultDescription": "Unset: requests go to Anthropic.",
              "title": "API endpoint",
              "description": "Send every request through this host.",
              "category": "Network",
              "risks": ["security", "privacy"],
              "status": "documented",
              "confirm": {
                "message": "Every prompt and file Claude reads will go to this host.",
                "appliesWhen": { "type": "onAnyChange" }
              },
              "docURL": "https://code.claude.com/docs/en/env-vars#variables"
            },
            {
              "id": "permissions.defaultMode",
              "location": { "type": "setting", "path": ["permissions", "defaultMode"] },
              "valueType": {
                "type": "enum",
                "options": [
                  { "value": "default", "label": "Ask" },
                  { "value": "acceptEdits", "label": "Accept edits" },
                  { "value": "plan", "label": "Plan" },
                  { "value": "bypassPermissions", "label": "Bypass" }
                ]
              },
              "defaultDescription": "Unset",
              "title": "Permission mode",
              "description": "The mode new sessions start in.",
              "category": "Safety",
              "risks": ["security"],
              "status": "documented",
              "userOnlyValues": ["bypassPermissions"],
              "confirm": {
                "message": "Bypass runs every tool without asking.",
                "appliesWhen": { "type": "whenValue", "value": "bypassPermissions" }
              },
              "notes": "auto and bypassPermissions only work from user settings.",
              "docURL": "https://code.claude.com/docs/en/settings-reference#permissions-defaultmode"
            },
            {
              "id": "permissions.disableBypassPermissionsMode",
              "location": { "type": "setting", "path": ["permissions", "disableBypassPermissionsMode"] },
              "valueType": { "type": "fixedString", "value": "disable" },
              "defaultDescription": "Unset: bypass mode is allowed.",
              "title": "Forbid bypass mode",
              "description": "Block bypassPermissions mode.",
              "category": "Safety",
              "risks": ["security"],
              "status": "documented",
              "docURL": "https://code.claude.com/docs/en/settings-reference#permissions-disablebypasspermissionsmode"
            }
          ]
        }
        """#

    static let envFixedString = tweak("envDisable", location: .env(name: "SOME_SWITCH"), valueType: .fixedString("disable"))

    static let envInteger = tweak("bashTimeout", location: .env(name: "BASH_DEFAULT_TIMEOUT_MS"), valueType: .integer(min: 1000, max: 600_000))

    static func catalog() throws -> Catalog {
        try CatalogLoader.load(data: Data(json.utf8))
    }

    static func catalog(_ tweaks: [Tweak]) -> Catalog {
        Catalog(researchDate: "2026-10-05", claudeCodeVersionChecked: "2.1.291", tweaks: tweaks)
    }

    static func tweak(
        _ id: String,
        location: Tweak.Location? = nil,
        valueType: Tweak.ValueType = .bool,
        defaultDescription: String = "Unset",
        status: Tweak.Status = .documented,
        minVersion: String? = nil,
        scope: Tweak.Scope = .any,
        requires: [Tweak.Requirement] = [],
        confirm: Tweak.Confirmation? = nil,
        overriddenBy: [Tweak.EnvOverride] = [],
        docURL: String? = nil
    ) -> Tweak {
        Tweak(
            id: id,
            location: location ?? .setting(path: [id]),
            valueType: valueType,
            defaultDescription: defaultDescription,
            title: "Title of \(id)",
            description: "Description of \(id)",
            category: "Test",
            status: status,
            minVersion: minVersion,
            scope: scope,
            requires: requires,
            confirm: confirm,
            overriddenBy: overriddenBy,
            docURL: docURL ?? "https://code.claude.com/docs/en/settings-reference#\(id.lowercased())"
        )
    }

    static func document(_ text: String) throws -> JSONDocument {
        try JSONScanner.scan([UInt8](text.utf8))
    }
}
