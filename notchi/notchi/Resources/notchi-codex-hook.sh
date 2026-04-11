#!/bin/bash
# Notchi Codex Hook - forwards Codex hook events to Notchi via Unix socket

SOCKET_PATH="/tmp/notchi.sock"

[ -S "$SOCKET_PATH" ] || exit 0

/usr/bin/python3 -c "
import json
import socket
import sys

try:
    input_data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

hook_event = input_data.get('hook_event_name', '')
status_map = {
    'SessionStart': 'waiting_for_input',
    'UserPromptSubmit': 'processing',
    'PreToolUse': 'running_tool',
    'PostToolUse': 'processing',
    'Stop': 'waiting_for_input',
}

output = {
    'provider': 'codex',
    'session_id': input_data.get('session_id', ''),
    'transcript_path': input_data.get('transcript_path'),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
    'status': status_map.get(hook_event, input_data.get('status', 'unknown')),
    'interactive': True,
    'model': input_data.get('model'),
}

tool = input_data.get('tool_name')
if tool:
    output['tool'] = tool

tool_use_id = input_data.get('tool_use_id')
if tool_use_id:
    output['tool_use_id'] = tool_use_id

tool_input = input_data.get('tool_input')
if tool_input:
    output['tool_input'] = tool_input

prompt = input_data.get('prompt')
if prompt:
    output['user_prompt'] = prompt

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    sock.close()
except Exception:
    pass
"
