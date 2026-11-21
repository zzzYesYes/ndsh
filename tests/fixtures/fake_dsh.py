#!/usr/bin/env python3
"""Fake dsh SDK runtime for ndsh integration tests.

Speaks the SDK wire protocol (ndjson JSON-RPC) over stdio. On session/query
it emits a scripted event sequence for the queried session id. A prompt
containing "approve" triggers a server-to-client approval/request before the
tool events, and the tool result echoes the granted outcome.
"""
import json
import sys
import time

seq = 0


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
    event(session_id, "assistant/message", {
        "turn": 1, "step": 1,
        "message": {"content": text_block("FAKE-INTRO: running a tool now")},
    })

    outcome = None
    if "approve" in text:
        send({
            "jsonrpc": "2.0", "id": "srv-1", "method": "approval/request",
            "params": {"sessionId": session_id, "toolName": "bash", "reason": "fake approval"},
        })
        # Block until the client's response to srv-1 arrives.
        for line in sys.stdin:
            reply = json.loads(line)
            if reply.get("id") == "srv-1":
                outcome = reply.get("result", {}).get("outcome")
                break
        event(session_id, "tool/call", {
            "turn": 1, "step": 1, "callId": "c-1", "name": "bash",
            "arguments": '{"command":"needs-approval"}',
        })
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
            time.sleep(0.05)
            run_query(msg)
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
            return


if __name__ == "__main__":
    main()
