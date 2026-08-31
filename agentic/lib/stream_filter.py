#!/usr/bin/env python3
"""Turn an agent CLI's NDJSON event stream into one readable line per event.

Reads the stream on stdin and does three things with it:

  * appends every raw line verbatim to RUN_DIR/agent-stream.jsonl, so the full
    detail survives for post-mortem even though stderr only gets a summary;
  * writes RUN_DIR/agent-state after each event (turns, events, last-event
    timestamp) for the heartbeat in common.sh to read;
  * watches for the same tool call repeating and flags it as a suspected loop,
    which is the case --max-turns and the wallclock cap only ever catch after
    the whole budget has already been spent;
  * prints a compact, truncated line per event to stderr, which is what shows up
    in `docker logs -f`.

Both backends frame their stream the same way -- Claude Code's
`--output-format stream-json` and Grok's `--output-format
streaming-messages-json` both emit {"type": "system"|"assistant"|"user"|
"result", ...} objects -- so one parser covers both. Anything unrecognised is
still counted, still stored, and still summarised generically: this must never
be the reason a run fails.

Nothing here may raise. A traceback would close the pipe and hand the agent a
SIGPIPE, turning an observability tool into the cause of a failed run.
"""
import collections
import datetime
import hashlib
import json
import os
import sys
import time

RUN_DIR = os.environ.get("RUN_DIR", ".")
STAGE = os.environ.get("STAGE", "agent")
MAXLEN = int(os.environ.get("AGENT_LOG_LINE_MAX", "200") or 200)

STATE = os.path.join(RUN_DIR, "agent-state")
RAW = os.path.join(RUN_DIR, "agent-stream.jsonl")
RESULT = os.path.join(RUN_DIR, "agent-result.json")
LOOP = os.path.join(RUN_DIR, "loop-suspect.json")


def _int_env(name, default):
    try:
        return max(1, int(os.environ.get(name) or default))
    except ValueError:
        return default


# An agent stuck re-running one failing command looks, to --max-turns and to the
# wallclock cap, exactly like an agent making progress -- both only fire once the
# budget is gone. Identical tool calls repeating inside a short window is the
# shape that distinguishes the two, and it is visible early.
LOOP_WINDOW = _int_env("LOOP_WINDOW", 20)
LOOP_REPEAT_LIMIT = _int_env("LOOP_REPEAT_LIMIT", 5)

# The field worth showing for a tool call, most specific first: one of these
# says what the agent is actually touching, which is the whole point of the line.
HINTS = ("file_path", "command", "path", "pattern", "url", "notebook_path", "prompt")


def clip(text, limit=None):
    """One line, no control characters, at most `limit` chars."""
    text = " ".join(str(text).split())
    limit = limit or MAXLEN
    return text if len(text) <= limit else text[: limit - 1] + "…"


def emit(msg):
    # Same format as common.sh's log() (`date -Iseconds`), so the filter's lines
    # and the shell's interleave as one coherent log.
    stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    print("%s [%s] %s" % (stamp, STAGE, msg), file=sys.stderr, flush=True)


def blocks_of(event):
    """Content blocks, whichever envelope the backend used."""
    msg = event.get("message")
    if not isinstance(msg, dict):
        msg = event if "content" in event else {}
    content = msg.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def describe(event):
    """(summary, is_turn) for one event; summary None means 'say nothing'."""
    etype = event.get("type")

    if etype == "system":
        if event.get("subtype") == "init":
            return "init model=%s tools=%s" % (
                event.get("model", "?"), len(event.get("tools") or [])), False
        return None, False

    if etype in ("assistant", "message") or event.get("role") == "assistant":
        parts = []
        for b in blocks_of(event):
            btype = b.get("type")
            if btype == "tool_use":
                inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                hint = next((f for f in HINTS if inp.get(f)), None)
                parts.append("tool=%s%s" % (
                    b.get("name", "?"),
                    " %s=%s" % (hint, clip(inp[hint], 90)) if hint else ""))
            elif btype == "text" and b.get("text", "").strip():
                parts.append("say: %s" % clip(b["text"], 120))
            elif btype == "thinking":
                parts.append("thinking")
        return ("; ".join(parts) if parts else None), True

    if etype == "user" or event.get("role") == "user":
        for b in blocks_of(event):
            if b.get("type") == "tool_result":
                body = b.get("content")
                if isinstance(body, list):
                    body = " ".join(x.get("text", "") for x in body
                                    if isinstance(x, dict))
                return "result=%s %s" % (
                    "ERR" if b.get("is_error") else "ok", clip(body or "", 120)), False
        return None, False

    if etype == "result":
        usage = event.get("usage") if isinstance(event.get("usage"), dict) else {}
        cost = event.get("total_cost_usd")
        return "done status=%s turns=%s cost=%s tokens=%s/%s in %ss" % (
            event.get("subtype", "?"),
            event.get("num_turns", "?"),
            ("$%.4f" % cost) if isinstance(cost, (int, float)) else "?",
            usage.get("input_tokens", "?"),
            usage.get("output_tokens", "?"),
            round((event.get("duration_ms") or 0) / 1000),
        ), False

    return "event type=%s" % etype, False


def tool_signature(block):
    """(signature, human label) for one tool_use block."""
    name = str(block.get("name", "?"))
    inp = block.get("input") if isinstance(block.get("input"), dict) else {}
    try:
        canonical = json.dumps(inp, sort_keys=True, default=str)
    except (TypeError, ValueError):
        canonical = repr(inp)
    hint = next((f for f in HINTS if inp.get(f)), None)
    label = "%s%s" % (name, " %s=%s" % (hint, clip(inp[hint], 80)) if hint else "")
    return name + ":" + hashlib.sha1(canonical.encode("utf-8", "replace")).hexdigest(), label


def main():
    raw = open(RAW, "a", buffering=1)
    turns = events = 0
    window = collections.deque(maxlen=LOOP_WINDOW)
    reported = set()

    def check_loop(event):
        """Flag a tool call that keeps repeating. Reports each signature once."""
        for block in blocks_of(event):
            if block.get("type") != "tool_use":
                continue
            sig, label = tool_signature(block)
            window.append(sig)
            repeats = list(window).count(sig)
            if repeats < LOOP_REPEAT_LIMIT or sig in reported:
                continue
            reported.add(sig)
            emit("LOOP-SUSPECT tool=%s repeats=%d/%d -- the same call keeps coming back"
                 % (label, repeats, len(window)))
            try:
                with open(LOOP, "w") as fh:
                    json.dump({"tool": block.get("name"), "label": label,
                               "repeats": repeats, "window": len(window),
                               "limit": LOOP_REPEAT_LIMIT,
                               "at_event": events, "ts": int(time.time())}, fh)
            except OSError:
                pass

    def save_state():
        # Written whole each time: the heartbeat only ever reads the last value,
        # and a torn read of a ~100-byte file is not worth locking against.
        try:
            tmp = STATE + ".tmp"
            with open(tmp, "w") as fh:
                json.dump({"turns": turns, "events": events,
                           "last_ts": int(time.time())}, fh)
            os.replace(tmp, STATE)
        except OSError:
            pass

    save_state()
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        events += 1
        try:
            raw.write(line + "\n")
        except OSError:
            pass

        try:
            event = json.loads(line)
        except ValueError:
            # Not JSON: a backend in plain-text mode, or a stray warning.
            emit(clip(line))
            save_state()
            continue

        try:
            if isinstance(event, dict) and event.get("type") == "result":
                with open(RESULT, "w") as fh:
                    json.dump(event, fh)
        except OSError:
            pass

        try:
            summary, is_turn = describe(event) if isinstance(event, dict) else (clip(line), False)
        except Exception as exc:                       # noqa: BLE001 - never fatal
            summary, is_turn = "unparsed event (%s)" % type(exc).__name__, False
        if is_turn:
            turns += 1
            try:
                check_loop(event)
            except Exception:                          # noqa: BLE001 - never fatal
                pass
        if summary:
            emit("turn=%d %s" % (turns, summary) if is_turn else summary)
        save_state()

    raw.close()
    save_state()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as exc:                           # noqa: BLE001 - never fatal
        emit("stream filter stopped: %s: %s" % (type(exc).__name__, exc))
