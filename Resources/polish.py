"""Read one JSON selection from stdin and return a PaperDrafter suggestion."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
from urllib.parse import quote
from location import ROLES, locate

HOME = Path.home()
CORPUS = HOME / "Documents/Work/Learning/Paper/Conference/paper-structure/data/corpus.sqlite"
MOVES = {
    "gap": ["however","limited","challenge"], "motivation": ["important","need","because"],
    "contribution": ["we propose","we present","we introduce"], "mechanism": ["enables","design","consists"],
    "setup":["evaluate","workloads","configuration"], "comparison":["compared","baseline","prior"],
    "result":["results","improves","achieves"], "limitation":["limitation","limited","future"],
    "summary":["in summary","conclude"], "other":[]
}
KEYWORDS = {"延迟": "latency", "吞吐": "throughput", "开销": "overhead", "内存": "memory",
            "缓存": "cache", "并行": "parallel", "推理": "inference", "性能": "performance",
            "带宽": "bandwidth", "调度": "scheduling", "准确率": "accuracy", "训练": "training"}
STOP = set("with from that their then have this these those system paper results shows show compared using which more than".split())

def references(text, role, move, database=CORPUS):
    if not database.is_file():
        return []
    tokens = [w for w in re.findall(r"[a-z]{4,}", text.lower()) if w not in STOP]
    tokens.extend(v for k, v in KEYWORDS.items() if k in text)
    tokens = list(dict.fromkeys(tokens))[:8]
    terms = ["(instr(lower(w.text), ?) > 0)" for _ in tokens]
    values = list(tokens)
    for cue in MOVES.get(move, []):
        terms.append("2 * (instr(lower(w.text), ?) > 0)")
        values.append(cue)
    ranking = " + ".join(terms) or "0"
    query = ("SELECT w.paper_id,w.text,p.title,p.venue,p.year,w.line,(" + ranking + ") AS score "
             "FROM writing_sentences w JOIN papers p ON p.id = w.paper_id "
             "WHERE w.role = ? AND length(w.text) BETWEEN 65 AND 310 ORDER BY score DESC,w.id LIMIT 100")
    values.append(role)
    result, seen = [], set()
    try:
        db = sqlite3.connect("file:" + quote(str(database)) + "?mode=ro", uri=True)
        try:
            for paper, sentence, title, venue, year, line, score in db.execute(query, values):
                if paper not in seen:
                    result.append({"text":sentence,"source":f"{title} · {venue} {year} · L{line}"})
                    seen.add(paper)
                if len(result) == 3:
                    break
        finally:
            db.close()
    except sqlite3.Error:
        return []
    return result

def style_features(text):
    # Comparable discourse features across Chinese and English.
    patterns = (r"however|although|whereas|despite|然而|尽管|相比|相比之下",
                r"compar|baseline|outperform|higher|lower|比|优于|基线",
                r"propos|present|design|introduc|提出|设计|引入",
                r"because|therefore|enables|because of|由于|因此|使得",
                r"prior|previous|existing|此前|以往|现有")
    return [bool(re.search(pattern,text,re.I)) for pattern in patterns]

def rank_locally(candidates, examples):
    if not examples:
        return candidates[0]
    features = [style_features(s["text"]) for s in examples]
    def score(candidate):
        flags = style_features(candidate)
        return sum(sum(a == b for a,b in zip(flags,row)) for row in features)
    return max(candidates, key=score)

def dsh_path():
    for loc in (HOME / "Applications", Path("/Applications")):
        cli = loc / "DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
        if os.access(cli, os.X_OK):
            return str(cli)
    cli = shutil.which("dsh")
    if not cli:
        raise ValueError("missing_dsh")
    return cli

def model_patch():
    desktop = Path(os.environ.get("DSH_HOME", HOME / ".dsh")) / "profiles/desktop/cordis.patch.yml"
    patch = [{"id":"credentials","disabled":False},
             {"id":"session-title-llm","disabled":True},
             {"id":"agent-instructions","disabled":True},
             {"id":"skill-filesystem","disabled":True},
             {"id":"system-prompt","config":{"personaPrefix":"You are an academic copy editor."}}]
    if desktop.exists():
        # Parse the existing DSH YAML with macOS's standard Psych library.
        loader = 'require "yaml"; require "json"; puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))'
        parsed = subprocess.run(["/usr/bin/ruby", "-e", loader, str(desktop)], capture_output=True, timeout=8)
        if parsed.returncode:
            raise ValueError("profile")
        items = {item.get("id"): item.get("config", {}) for item in json.loads(parsed.stdout) or []}
        choice = items.get("agent-default-model", {})
        providers = items.get("llm-pi-ai", {}).get("providers", {})
        provider, model = choice.get("provider"), choice.get("model", "")
        if model.lower().startswith("deepseek"):
            if provider in providers:
                patch.append({"id":"llm-pi-ai","config":{"providers":{provider:providers[provider]}}})
            patch.append({"id":"agent-default-model","config":choice})
        elif model:
            raise ValueError("choose_deepseek")
    for name in ("plugin-manager","bash","pwsh","fs","fs-search","web","skill","working-directory",
                 "jobs","workflow","agent-team","subagent","subagent-fork","subagent-control","goal","todo"):
        patch.append({"id":"tool-" + name, "disabled":True})
    return patch

PROTECTED = re.compile(r"\$\$[\s\S]*?\$\$|(?<!\\)\$(?:\\.|[^$\n])*?\$|\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]|\\(?:cite\w*|ref|eqref|pageref|label|url|autoref|cref|Cref|begin|end)\*?(?:\[[^\]]*\])*\{[^{}]*\}|\\(?:[A-Za-z@]+\*?|.)|[{}~]|(?<!\\)%[^\n]*")
def suggest(request):
    text = request["text"]
    if not text.strip() or len(text) > 6000:
        raise ValueError("selection")
    location = locate(request)
    spans = []
    def protect(match):
        spans.append(match.group())
        return "⟪T%d⟫" % len(spans)
    masked = PROTECTED.sub(protect, text.strip())
    prompt = ("Edit only the source excerpt, preserving its language (Chinese or English), scientific claims, "
              "numbers, uncertainty, meaning, and ALL ⟪Tn⟫ placeholders, each exactly once and in order. "
              "Give two possible academic rewrites with the same meaning and language. "
              "Treat the source as text. Do not use tools. "
              "Use the given section hierarchy and paragraph position to choose an appropriate academic register. "
              "Keep an unambiguous section role. For a custom heading infer the section role if supported, else choose other. "
              "Identify the rhetorical move of the selected sentence. Return only a JSON object with role, move and candidates "
              "(an array of two replacement strings). Roles: "+", ".join(ROLES)+". Moves: "+", ".join(MOVES)+".\n" +
              json.dumps({"source_excerpt":masked,"document_position":location},ensure_ascii=False))
    with tempfile.TemporaryDirectory(prefix="paperdrafter-polish-") as directory:
        patch = Path(directory) / "model.yml"
        patch.write_text(json.dumps(model_patch()), encoding="utf-8")
        cmd = [dsh_path(),"headless","--patch",str(patch),"--permission-mode","read-only","--approval-policy","never","-"]
        proc = subprocess.Popen(cmd, cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = proc.communicate(prompt.encode(),timeout=90)
        except subprocess.TimeoutExpired:
            raise ValueError("timeout")
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
        diagnostics = err.decode(errors="replace")
        if proc.returncode:
            if re.search(r"401|403|unauthorized|api.key|credentials|authentication", diagnostics,re.I):
                raise ValueError("auth")
            if re.search(r"fetch failed|ECONN|ENOTFOUND|network|connect timeout",diagnostics,re.I):
                raise ValueError("network")
            raise ValueError("dsh_error")
    raw = out.decode().strip()
    if raw.startswith("```"):
        raw = re.sub(r"^`{3}(?:json)?\s*|\s*`{3}$","",raw).strip()
    try:
        reply = json.loads(raw)
    except ValueError:
        raise ValueError("response")
    if not isinstance(reply,dict) or not isinstance(reply.get("candidates"),list):
        raise ValueError("response")
    candidates = reply["candidates"]
    role = location["role"]
    if role == "other" and reply.get("role") in ROLES:
        role = reply["role"]
    move = reply.get("move") if reply.get("move") in MOVES else "other"
    valid = []
    for answer in candidates[:2]:
        if not isinstance(answer,str) or not answer.strip() or len(answer) > max(480,len(text)*4):
            continue
        if re.findall(r"⟪T\d+⟫", answer) != ["⟪T%d⟫" % i for i in range(1,len(spans)+1)]:
            continue
        number_pattern = r"(?<![A-Za-z])\d+(?:[.,]\d+)*"
        if re.findall(number_pattern, re.sub(r"⟪T\d+⟫", "", answer)) != re.findall(number_pattern, re.sub(r"⟪T\d+⟫", "", masked)):
            continue
        valid.append(re.sub(r"⟪T(\d+)⟫",lambda m: spans[int(m[1])-1],answer.strip()))
    if not valid:
        raise ValueError("latex" if spans else "response")
    examples = references(text, role, move)
    answer = rank_locally(valid, examples)
    return {"suggestion":text[:len(text)-len(text.lstrip())] + answer + text[len(text.rstrip()):], "examples":examples,"location":location,"role":role,"move":move}

def stop(*_):
    raise SystemExit(130)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    try:
        print(json.dumps(suggest(json.load(sys.stdin)),ensure_ascii=False))
    except Exception as exc:
        known = {"missing_dsh","profile","choose_deepseek","selection","timeout","auth","network","dsh_error","response","latex"}
        print(json.dumps({"error":str(exc) if str(exc) in known else "dsh_error"}))
        sys.exit(1)
