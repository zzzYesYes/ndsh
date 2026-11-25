#!/usr/bin/env python3
"""Fake dsh SDK runtime for ndsh integration tests.

Speaks the SDK wire protocol (ndjson JSON-RPC) over stdio. On session/query
it emits a scripted event sequence for the queried session id. A prompt
containing "approve" triggers a server-to-client approval/request before the
tool events, and the tool result echoes the granted outcome.

Like real dsh, wire sessions persist across processes: with FAKE_DSH_STORE
set, session/query records the session id in that file and session/resume
accepts any recorded id (plus "persisted-*" fixture ids), so a restarted
runtime resumes earlier sessions instead of starting fresh.
"""
import json
import os
import sys
import time

seq = 0

STORE = os.environ.get("FAKE_DSH_STORE")


def known_sessions():
    if not STORE:
        return set()
    try:
        with open(STORE) as f:
            return set(line.strip() for line in f if line.strip())
    except OSError:
        return set()


def mark_known(session_id):
    if not STORE:
        return
    with open(STORE, "a") as f:
        f.write(session_id + "\n")


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def event(session_id, ev_type, data):
    global seq
    seq += 1
    notify("session.event", {
        "sessionId": session_id,
        "event": {"type": ev_type, "seq": seq, "time": 0, "data": data},
    })


def text_block(text):
    return [{"type": "text", "text": text}]


def run_query(msg):
    params = msg["params"]
    session_id = params["sessionId"]
    text = "".join(b.get("text", "") for b in params["contentBlocks"])

    send({"jsonrpc": "2.0", "id": msg["id"], "result": {"kind": "prompt", "messageId": "m-1"}})
    notify("session.status", {"sessionId": session_id, "status": "running"})
    event(session_id, "turn/start", {"turn": 1})
    event(session_id, "user/message", {
        "content": text_block(text), "source": {"kind": "user"},
    })
    event(session_id, "request/context", {
        "provider": "fake", "model": "fake-v1", "contextWindow": 128000,
    })
    if text.startswith("/plan"):
        event(session_id, "plan/mode", {"active": text.strip() != "/plan off"})
    event(session_id, "assistant/message", {
        "turn": 1, "step": 1,
        "message": {"content": [
            {"type": "reasoning", "text": "thinking about the right tool"},
            {"type": "text", "text": "FAKE-INTRO: running a tool now"},
        ]},
        "usage": {"inputTokens": 12345, "outputTokens": 42},
    })

    outcome = None
    if "approve" in text:
        # Real runtime order: the tool/call event lands when the call is
        # admitted, before the approval gates its execution.
        event(session_id, "tool/call", {
            "turn": 1, "step": 1, "callId": "c-1", "name": "bash",
            "arguments": '{"command":"needs-approval"}',
        })
        send({
            "jsonrpc": "2.0", "id": "srv-1", "method": "approval/request",
            "params": {"sessionId": session_id, "toolName": "bash", "callId": "c-1", "reason": "fake approval"},
        })
        # Block until the client's response to srv-1 arrives.
        for line in sys.stdin:
            reply = json.loads(line)
            if reply.get("id") == "srv-1":
                outcome = reply.get("result", {}).get("outcome")
                break
        event(session_id, "tool/result", {
            "turn": 1, "step": 1,
            "message": {
                "toolCallId": "c-1",
                "content": text_block("approval outcome: %s" % outcome),
                "isError": outcome != "allowed-once",
            },
        })
    else:
        event(session_id, "tool/call", {
            "turn": 1, "step": 1, "callId": "c-1", "name": "bash",
            "arguments": '{"command":"echo hi"}',
        })
        event(session_id, "tool/result", {
            "turn": 1, "step": 1,
            "message": {
                "toolCallId": "c-1",
                "content": text_block("fake output line 1\nfake output line 2"),
                "isError": False,
            },
        })

    event(session_id, "assistant/message", {
        "turn": 1, "step": 2,
        "message": {"content": text_block("FAKE-OUTRO: %s" % text)},
    })
    event(session_id, "turn/end", {"turn": 1, "reason": "complete"})
    notify("session.status", {"sessionId": session_id, "status": "idle"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        if "method" not in msg:
            continue
        method = msg["method"]
        if method == "initialize":
            send({
                "jsonrpc": "2.0", "id": msg["id"],
                "result": {"serverInfo": {"name": "deepseek-harness-sdk-runtime", "version": "0.0.0-fake"}},
            })
        elif method == "session/query":
            mark_known(msg["params"]["sessionId"])
            time.sleep(0.05)
            run_query(msg)
        elif method == "session/resume":
            sid = msg["params"]["sessionId"]
            if sid.startswith("persisted-") or sid in known_sessions():
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
            else:
                send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32602, "message": "unknown session"}})
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
            return


if __name__ == "__main__":
    main()
