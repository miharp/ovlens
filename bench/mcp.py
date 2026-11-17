#!/usr/bin/env python3
"""Times ovlens MCP calls against a docs directory and shows what comes back:
start-up, the first search in an environment (which builds its index), later
searches and lookups, and the server's memory while it visits every
environment.

    mcp.py <docs-dir>

OVLENS_CMD is the command to start, "ovlens" by default.
"""
import json, subprocess, sys, time

import os, shlex
command = shlex.split(os.environ.get("OVLENS_CMD", "ovlens"))
proc = subprocess.Popen(command + ["mcp", "--docs-dir", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
n = 0
def rpc(method, params=None):
    global n
    n += 1
    msg = {"jsonrpc": "2.0", "id": n, "method": method}
    if params is not None:
        msg["params"] = params
    t = time.time()
    proc.stdin.write(json.dumps(msg) + "\n"); proc.stdin.flush()
    line = proc.stdout.readline()
    return json.loads(line), (time.time() - t) * 1000

def rss():
    for line in open(f"/proc/{proc.pid}/status"):
        if line.startswith("VmRSS"):
            return int(line.split()[1]) // 1024

def call(tool, args, show=None):
    r, ms = rpc("tools/call", {"name": tool, "arguments": args})
    res = r["result"]; text = res["content"][0]["text"]
    try: data = json.loads(text)
    except ValueError: data = {}
    extra = show(data) if show and data else ""
    print(f"{ms:7.0f} ms {len(text):7d} chars  {tool} {json.dumps(args)[:70]:70s} {extra}")
    return data

t = time.time()
rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "0"}})
print(f"start + initialize: {(time.time()-t)*1000:.0f} ms, rss {rss()} MB")
top = lambda d: f"matches={d.get('matches')} match={d.get('match')} top={[x['name'] for x in d.get('results', [])[:4]]}"
call("list_modules", {}, lambda d: f"modules={len(d['modules'])} envs={len(d['environments'])}")
call("search_code", {"text": "apache"}, top); print(f"   (first search builds the corpus; rss now {rss()} MB)")
for q in ["apache", "reverse proxy", "ssl certificate", "create a user", "firewall rule", "ntp server", "logrotate", "docker container", "postgresql database", "package", "manage"]:
    call("search_code", {"text": q}, top)
call("search_code", {"text": "vhost", "type": "defined_types"}, top)
call("search_code", {"module": "kubernetes"}, lambda d: f"matches={d['matches']} returned={d['returned']}")
call("search_code", {"text": "user", "limit": 200}, lambda d: f"matches={d['matches']} returned={d['returned']}")
call("search_code", {"text": "apache", "environment": "team07_feature"}, top); print(f"   (second environment's corpus; rss now {rss()} MB)")
det = lambda d: f"detail={[r.get('detail','full') for r in d.get('results', [])]} omitted={d.get('omitted')}"
call("get_docs", {"name": "apache"}, det)
call("get_docs", {"name": "apache::vhost"}, det)
call("get_docs", {"names": ["apache::vhost"], "parameters": ["docroot", "proxy_pass", "ssl"]}, det)
call("get_docs", {"names": ["nginx", "postgresql::server", "docker", "mysql::server", "haproxy", "kubernetes"]}, det)
call("get_docs", {"name": "firewall", "type": "resource_types"}, det)
print(f"before visiting every environment: rss {rss()} MB")
envs = json.loads(rpc("tools/call", {"name": "list_modules", "arguments": {}})[0]["result"]["content"][0]["text"])["environments"]
for i, env in enumerate(envs, 1):
    r, ms = rpc("tools/call", {"name": "search_code", "arguments": {"text": "apache", "environment": env}})
    if i % 10 == 0:
        print(f"  after searching {i} environments: rss {rss()} MB (last first search {ms:.0f} ms)")
print(f"end: rss {rss()} MB")
proc.stdin.close()
