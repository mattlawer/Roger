# Roger

Roger is a native macOS chat app, in the spirit of Claude, that runs entirely on local
[Ollama](https://ollama.com) models. It answers questions, writes code, analyses bugs,
reads and edits files in a working directory, and suggests or runs shell commands with
your approval.

## Features

- Chat with any installed Ollama model, with streaming responses and Markdown rendering.
- Attach files (drag & drop onto the message box or the paperclip) and paste images from the
  clipboard; images are passed to vision-capable models. Return sends, ⌥⏎ adds a line.
- Pick a working directory per chat. Tool-capable models can `read_file`, `write_file`,
  `edit_file`, `list_directory`, `search_files` and `run_command`.
- Writes, edits and commands show a preview (with a diff) and wait for your approval.
  Command output streams live while it runs, and stopping generation stops the command.
- "Always allow…" remembers approvals per working directory: read-only commands, commands
  like `swift build`, any command, or file edits. Manage them in Settings → Tools.
- Code blocks are syntax highlighted (Swift, Python, JS/TS, Go, Rust, C-family, shell, JSON,
  YAML, SQL, HTML, diff and more), with the language guessed when the fence has no tag.
- Images the model references (Markdown images or bare paths like `plot.png`) render inline;
  click one, or any attachment, for a Quick Look preview.
- Thinking models: show reasoning in a collapsible section, hide it, or turn it off. A model
  that answers only inside its reasoning gets that reasoning shown as the reply, labelled.
- Optional web access (Settings → Internet, off by default): `web_search` through DuckDuckGo
  or your own SearXNG instance, and `fetch_url` to read pages and PDFs as text. Route those
  requests directly, through an HTTP or SOCKS5 proxy, or through Tor. Roger detects a running
  Tor (9050, or Tor Browser's 9150), can start an installed `tor` for you, or copies the
  command to run or install it. "Test connection" shows your exit IP and whether it is Tor.
  The sidebar footer shows the web route next to the Ollama status, with a menu to test the
  connection, request a new Tor circuit (NEWNYM over the control port when available,
  otherwise SIGHUP), send SIGHUP explicitly, or start and stop Tor.
- Shell code blocks get a Run button, with the output sendable back to the model.
- Manage models: installed models with size on disk, parameter count, quantization, context
  window and an estimated memory footprint at your context setting; expand a row for
  architecture details (layers, heads, KV cache per token, license, base model). Pull new
  models with progress and cancel, delete models, and see or unload what is loaded in memory.
- Chats are named automatically by the model after the first exchange (rename to pin a
  name, or pick "Generate Name" to redo it).
- Group chats into folders in the sidebar: drag a chat onto a group, or use "Move to" in
  its context menu. ⇧⌘N creates a group; a group's context menu renames or removes it.
- Search chats (⌘F) by title or message content; matches are highlighted in the chat.
- Every reply shows which model produced it, with Ollama's token counts on hover.
- Edit any earlier message and resend from that point, or regenerate the last reply.
- Stop a reply and keep what was produced so far; partial replies are marked as such.
- A "Jump to latest" button appears when you scroll up during a long reply; the view
  only auto-follows while you are at the bottom.
- Context budget meter in the composer: an estimate of the chat's size against the
  model's context window, with a warning when it no longer fits. By default the oldest
  turns are trimmed from what is sent (never from the chat itself); a divider shows where
  the model's view starts.
- Conversations are saved locally in `~/Library/Application Support/Roger`.

## Build

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Roger.app
```

Or open `Roger.xcodeproj` in Xcode and press Run.

## UI test suite

`Scripts/UITest/suite.sh` drives the running app through the Accessibility API: it creates a
chat, picks a model, and sends a series of prompts (plain reply, file listing, a shell command
that needs approval, a Swift code block, a web search, a reply it stops midway, a thinking-model
question, regenerate), then checks the sidebar search, the context meter, the web status and
the "jump to latest" pill. Results are checked on screen and in the saved chat JSON. It needs
Accessibility permission for your terminal, Ollama with `qwen2.5:14b` and
`jaahas/qwen3.5-uncensored`, and takes about three minutes.

```bash
Scripts/UITest/suite.sh
```

## Requirements

- macOS 14 or later.
- Ollama running locally (`brew install ollama`, then `ollama serve` or the Ollama app).
- A model that supports tool calling (for example `qwen2.5-coder:7b`, `qwen3:8b`,
  `llama3.1:8b`) for file and command tools. Models without tool support still work
  for chat and command suggestions.
