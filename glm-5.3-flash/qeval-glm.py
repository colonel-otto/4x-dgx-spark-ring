#!/usr/bin/env python3
"""MiaAI qeval (scripts/qeval.py, 75 tasks, temp 0, c=1) pointed at GLM-5.3-Flash.
Tasks and checkers are unchanged; only the request differs: model glm-5.3-flash, reasoning_effort "low" for
tasks DSv4.1 runs with thinking off and "max" (GLM default) for its thinking tasks, and max_tokens raised by
+8192 because GLM always emits a reasoning block first. Scores are content-only, as in qeval. Indicative,
not a paired comparison with the DSv4.1 runs."""
import json, sys, time, urllib.request
sys.path.insert(0, "/home/sparkmain/dsv41/miaai/scripts")
import qeval

def ask(url, task, timeout):
    body = {"model": "glm-5.3-flash", "temperature": 0, "max_tokens": task["max_tokens"] + 8192, "stream": False,
            "chat_template_kwargs": {"reasoning_effort": "max" if task["thinking"] else "low"},
            "messages": [{"role": "user", "content": task["prompt"]}]}
    t0 = time.time()
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=timeout)); dt = time.time() - t0
    ch = r["choices"][0]; msg = ch["message"]; n = r["usage"]["completion_tokens"]
    return {"content": msg.get("content") or "",
            "reasoning_chars": len(msg.get("reasoning_content") or msg.get("reasoning") or ""),
            "finish_reason": ch.get("finish_reason"), "completion_tokens": n,
            "seconds": round(dt, 3), "tok_s": round(n / dt, 2) if dt > 0 else None, "spec": None}

qeval.ask = ask
if __name__ == "__main__":
    sys.argv[0] = qeval.__file__
    exec(compile(open(qeval.__file__).read().split('if __name__ == "__main__":', 1)[1].replace("\n    ", "\n"),
                 qeval.__file__, "exec"), vars(qeval))
