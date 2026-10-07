import json, sys, glob, os, time
D = os.path.expanduser("~/Library/Application Support/Roger/Conversations")
def latest():
    files = glob.glob(D + "/*.json"); return max(files, key=os.path.getmtime)
def load(f): return json.load(open(f))
cmd = sys.argv[1]
if cmd == "latest": print(latest())
elif cmd == "done":   # last message is a finished assistant turn
    c = load(sys.argv[2]); m = c["messages"][-1] if c["messages"] else None
    ok = m and m["role"] == "assistant" and (m["content"] or m.get("toolCalls") or m.get("error"))
    sys.exit(0 if ok else 1)
elif cmd == "last":
    c = load(sys.argv[2]); ms = [m for m in c["messages"] if m["role"] == "assistant"]; m = ms[-1]
    print(json.dumps({"content": m["content"][:300], "model": m.get("model"), "stopped": m.get("stopped"), "thinking_len": len(m.get("thinking") or ""),
                      "answeredInReasoning": m.get("answeredInReasoning"), "stats": m.get("stats"), "error": m.get("error"), "id": m["id"],
                      "tools": [(t["name"], t["status"], (t.get("result") or "")[:120], t.get("approvedBy")) for t in m.get("toolCalls", [])]}, ensure_ascii=False))
elif cmd == "tools":   # all tool calls in the chat
    c = load(sys.argv[2]); print(json.dumps([(t["name"], t["status"], (t.get("result") or "")[:200]) for m in c["messages"] for t in m.get("toolCalls", [])], ensure_ascii=False))
elif cmd == "title": c = load(sys.argv[2]); print(json.dumps({"title": c["title"], "generated": c.get("titleGenerated"), "custom": c.get("titleIsCustom"), "group": c.get("groupID")}))
elif cmd == "count": print(len(load(sys.argv[2])["messages"]))
elif cmd == "field": c = load(sys.argv[2]); print(c.get(sys.argv[3]))
