#!/usr/bin/env python3
"""Windows Terminal 用の軽量な Codex ステータス表示。標準ライブラリのみ使用。"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time

PALETTE = {
    "cyan": "38;2;0;180;180",
    "blue": "38;2;0;128;255",
    "gray": "38;2;190;190;190",
    "yellow": "38;2;255;215;0",
}


def config_defaults(codex_home):
    try:
        text = (codex_home / "config.toml").read_text(encoding="utf-8")
    except OSError:
        return {}
    values = {}
    for key, name in (("model", "model"), ("model_reasoning_effort", "effort")):
        match = re.search(rf'^\s*{key}\s*=\s*["\']([^"\']+)["\']\s*$', text, re.MULTILINE)
        if match:
            values[name] = match.group(1)
    return values


def run(args, cwd, timeout=3):
    try:
        result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=timeout, check=False)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def git_info(cwd):
    def git(*args):
        return run(["git", "--no-optional-locks", *args], cwd)

    if not git("rev-parse", "--show-toplevel"):
        return None
    branch = git("symbolic-ref", "--quiet", "--short", "HEAD")
    if not branch:
        branch = git("rev-parse", "--short", "HEAD") or b"detached"
    status = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    staged = modified = 0
    if status is not None:
        records = iter(status.split(b"\0"))
        for record in records:
            if len(record) < 3:
                continue
            if record[:2] == b"??":
                modified += 1
                continue
            staged += record[:1] != b" "
            modified += record[1:2] != b" "
            if record[:1] in (b"R", b"C") or record[1:2] in (b"R", b"C"):
                next(records, None)
    return {"branch": branch.decode(errors="replace").strip(), "staged": staged, "modified": modified}


def find_session(codex_home, cwd, since):
    newest = None
    for path in (codex_home / "sessions").rglob("*.jsonl"):
        try:
            if path.stat().st_mtime < since:
                continue
            first = json.loads(path.open(encoding="utf-8").readline())
            payload = first.get("payload", {})
            if first.get("type") == "session_meta" and Path(payload.get("cwd", "")).resolve() == cwd:
                if newest is None or path.stat().st_mtime > newest.stat().st_mtime:
                    newest = path
        except (OSError, ValueError):
            continue
    return newest


class SessionReader:
    def __init__(self, path):
        self.path, self.offset, self.state = path, 0, {}

    def poll(self):
        try:
            with self.path.open("rb") as stream:
                stream.seek(self.offset)
                for line in stream:
                    self.offset = stream.tell()
                    try:
                        event = json.loads(line)
                        payload = event.get("payload", {})
                        if event.get("type") == "turn_context":
                            collaboration = payload.get("collaboration_mode")
                            self.state.update(model=payload.get("model"), effort=payload.get("effort"),
                                              mode=collaboration.get("mode") if isinstance(collaboration, dict) else collaboration)
                        elif event.get("type") == "event_msg" and payload.get("type") == "token_count":
                            info = payload.get("info", {})
                            usage = info.get("last_token_usage", {})
                            self.state["context"] = (usage.get("total_tokens"), info.get("model_context_window"))
                    except (ValueError, AttributeError):
                        continue
        except OSError:
            pass
        return self.state


def account_limits():
    codex = shutil.which("codex.cmd" if os.name == "nt" else "codex")
    if not codex:
        return None
    process = None
    inbox = queue.Queue()
    try:
        process = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
        threading.Thread(target=lambda: [inbox.put(json.loads(line)) for line in process.stdout if line.strip()], daemon=True).start()

        def send(message):
            process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            process.stdin.flush()

        def receive(request_id):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    message = inbox.get(timeout=max(0.1, deadline - time.monotonic()))
                    if message.get("id") == request_id:
                        return message
                except queue.Empty:
                    pass
            return {}

        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "codex-statusline", "version": "1"}, "capabilities": {"experimentalApi": True}}})
        receive(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "account/rateLimits/read", "params": None})
        limits = receive(2).get("result", {}).get("rateLimits", {})
        return {name: limits.get(name) for name in ("primary", "secondary") if isinstance(limits.get(name), dict)}
    except (OSError, BrokenPipeError, AttributeError, TypeError, ValueError):
        return None
    finally:
        if process:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()


def percentage(context):
    try:
        tokens, window = context
        return 100 * tokens / window if window else None
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def reset_at(value, minutes):
    try:
        fmt = "%m/%d %H:%M" if minutes >= 1440 else "%H:%M"
        return dt.datetime.fromtimestamp(value).astimezone().strftime(fmt)
    except (TypeError, ValueError, OSError):
        return None


ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def clip(line, columns):
    """表示幅で切り詰める。ANSI エスケープは幅を持たないので予算から除外する。"""
    width = 0
    out = []
    position = 0
    for match in ANSI_RE.finditer(line):
        for char in line[position:match.start()]:
            if width >= columns:
                return "".join(out) + "\033[0m"
            out.append(char)
            width += 1
        out.append(match.group())
        position = match.end()
    for char in line[position:]:
        if width >= columns:
            break
        out.append(char)
        width += 1
    return "".join(out)


def render(state, color, columns):
    def paint(text, shade):
        return f"\033[{PALETTE[shade]}m{text}\033[0m" if color else str(text)

    def item(label, value, value_color="cyan", label_color="cyan"):
        return paint(label + ":", label_color) + " " + paint(value, value_color)

    sep = paint(" | ", "gray")
    lines = []
    first = [item("Model", state.get("model", "N/A")), item("Thinking", state.get("effort", "N/A"))]
    context = percentage(state.get("context"))
    if context is not None:
        first.append(item("Ctx Used", f"{context:.1f}%"))
    lines.append(sep.join(first))

    second = [item("cwd", state["cwd"], "blue", "blue")]
    git = state.get("git")
    if git:
        second.extend((paint("~ " + git["branch"], "blue"), paint(f"(+{git['staged']},~{git['modified']})", "blue")))
    lines.append(sep.join(second))

    third = []
    for usage, reset, window in (("Session", "Reset", state.get("limits", {}).get("primary")), ("Weekly", "Weekly Reset", state.get("limits", {}).get("secondary"))):
        if not window:
            continue
        used, minutes = window.get("usedPercent"), window.get("windowDurationMins")
        if isinstance(used, (int, float)):
            third.append(item(usage, f"{used:.1f}%", "blue", "blue"))
        date = reset_at(window.get("resetsAt"), minutes)
        if date:
            third.append(item(reset, date, "gray", "blue"))
    if third:
        lines.append(sep.join(third))

    if state.get("mode"):
        lines.append(paint(">> ", "yellow") + item("Mode", state["mode"], "yellow", "yellow"))
    return "\n".join(clip(line, columns) for line in lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--since", type=float, default=0)
    parser.add_argument("--stop-file")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=float, default=2)
    args = parser.parse_args()
    cwd = Path(args.cwd).resolve()
    home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    state = {**config_defaults(home), "cwd": str(cwd)}
    reader = None
    next_find = next_limits = 0
    interactive = sys.stdout.isatty() and not args.once
    color = interactive
    try:
        if interactive:
            sys.stdout.write("\033[?1049h\033[?25l")
        while True:
            if args.stop_file and Path(args.stop_file).exists():
                return
            now = time.monotonic()
            if reader is None and now >= next_find:
                path = find_session(home, cwd, args.since)
                if path:
                    reader = SessionReader(path)
                # codex がセッションを書き出すまで数秒かかる。見つかるまでは
                # 短い間隔で探し、Ctx Used / Mode が出るまでの空白を縮める。
                next_find = now + (5 if reader else 1)
            if reader:
                state.update({k: v for k, v in reader.poll().items() if v is not None})
            if now >= next_limits:
                limits = account_limits()
                if limits:
                    state["limits"] = limits
                next_limits = now + 60
            state["git"] = git_info(str(cwd))
            columns = shutil.get_terminal_size((100, 4)).columns - 1
            output = render(state, color, max(1, columns))
            if interactive:
                sys.stdout.write("\033[H\033[J" + output + "\033[0m")
                sys.stdout.flush()
            else:
                print(output)
            if args.once:
                return
            time.sleep(args.interval)
    finally:
        if interactive:
            sys.stdout.write("\033[0m\033[?25h\033[?1049l")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
