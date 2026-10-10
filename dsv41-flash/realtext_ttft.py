#!/usr/bin/env python3
"""Cold TTFT on natural text (source code + docs), unique nonce prefix so nothing hits the prefix cache.
usage: realtext_ttft.py <tokens> <reps> [nonce]"""
import json, sys, time, urllib.request, os
N, R = int(sys.argv[1]), int(sys.argv[2]); tag = sys.argv[3] if len(sys.argv) > 3 else str(time.time_ns())
corpus = open(os.path.join(os.path.dirname(__file__), "corpus.txt"), errors="ignore").read()
for r in range(R):
    off = (r * 7919 * 1000) % max(1, len(corpus) - N * 4)
    text = f"[{tag}-{r}] Summarize the following code in one sentence.\n" + corpus[off: off + N * 3]
    body = json.dumps({"model": "deepseek-v4.1-flash", "messages": [{"role": "user", "content": text}], "max_tokens": 8,
                       "temperature": 0, "stream": True, "stream_options": {"include_usage": True},
                       "chat_template_kwargs": {"thinking": False}}).encode()
    t0 = time.time(); first = None; ptok = None
    req = urllib.request.Request("http://127.0.0.1:8100/v1/chat/completions", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as f:
        for line in f:
            if not line.startswith(b"data: ") or line.strip() == b"data: [DONE]": continue
            d = json.loads(line[6:])
            if first is None and d.get("choices") and d["choices"][0]["delta"].get("content"): first = time.time()
            if d.get("usage"): ptok = d["usage"]["prompt_tokens"]
    print(f"prompt_tokens={ptok} ttft={first - t0:.2f}s prefill={ptok / (first - t0):.0f} tok/s", flush=True)
