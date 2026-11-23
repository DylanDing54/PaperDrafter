"""Resolve an editor selection against the LaTeX input tree, entirely on this Mac."""
from pathlib import Path
import re

ROLES = {
    "abstract": r"abstract|摘要",
    "related": r"related work|prior work|literature review|相关工作|研究现状",
    "methodology": r"methodology|experiment(?:al)? (?:method|setup|settings)|testbed|实验方法|实验设置|实验环境",
    "evaluation": r"evaluation|results?|performance analysis|measurements?|experiments?|评估|评测|评价|实验|结果",
    "introduction": r"introduction|引言|导论|绪论",
    "background": r"background|motivation|preliminar|背景|动机|预备知识",
    "problem": r"problem|formulation|system model|问题|建模",
    "overview": r"overview|方案概览|概述|总览|总体架构",
    "implementation": r"implementation|实现",
    "discussion": r"discussion|limitations?|future work|讨论|局限|未来工作",
    "conclusion": r"conclu|总结|结论",
    "design": r"design|our approach|proposed method|architecture|algorithm|系统设计|方法|架构|算法|设计",
    "other": r"(?!)",
}
COMMAND = re.compile(r"\\(chapter|section|subsection|subsubsection|paragraph|begin|end|input|include|subfile|import|subimport|abstract)\b\*?\s*(?:\[[^\]]*\]\s*)?")
LEVELS = ["chapter","section","subsection","subsubsection","paragraph"]
SKIP = re.compile(r"(?<!\\)%[^\n]*|\\begin\{(verbatim\*?|lstlisting|minted|comment)\}[\s\S]*?\\end\{\1\}|\\verb\*?([^\w\s])[^\n]*?\2")

def group(source, i):
    if i >= len(source) or source[i] != "{":
        return "", i
    start, depth = i + 1, 1
    i += 1
    while i < len(source):
        ch = source[i]
        if ch == "\\":
            i += 2
            continue
        depth += (ch == "{") - (ch == "}")
        if depth == 0:
            return source[start:i], i + 1
        i += 1
    return "", start

def classify(path):
    for title in path:
        for role, pattern in ROLES.items():
            if re.search(pattern,title,re.I):
                return role
    return "other"

def locate(request):
    source = request.get("source","")
    # AppKit ranges use UTF-16 code units.
    pos = len(source.encode("utf-16-le")[:2*request.get("offset",0)].decode("utf-16-le","ignore"))
    end = pos + len(request["text"])
    root = Path(request.get("root",".")).resolve()
    target = Path(request.get("file","selection.tex")).resolve()
    main = Path(request.get("main") or target).resolve()
    titles = [""] * len(LEVELS)
    state = {"abstract":False,"steps":0,"text":[]}
    def visit(path, parents):
        path = path.resolve()
        if path in parents or len(parents)>32 or state["steps"]>=2000 or not path.is_relative_to(root):
            return False
        state["steps"] += 1
        try:
            content = source if path == target else path.read_text(encoding="utf-8-sig")
        except (OSError,UnicodeError):
            return False
        # Replace excluded regions at full length before clipping to the selection.
        clean = SKIP.sub(lambda m: "".join("\n" if c=="\n" else " " for c in m[0]),content)
        if path == target:
            clean = clean[:pos]
        i = 0
        while True:
            match = COMMAND.search(clean,i)
            if match is None:
                state["text"].append(clean[i:])
                break
            state["text"].append(clean[i:match.start()])
            cmd = match[1]
            arg,i = group(clean,match.end())
            if i == match.end() and cmd == "input":
                plain = re.match(r"[^\\\s{}%]+",clean[i:])
                if plain:
                    arg = plain[0]; i += len(arg)
            if cmd in LEVELS:
                level = LEVELS.index(cmd)
                titles[level:] = [arg.strip()[:160]] + [""]*(len(titles)-level-1)
                state["text"].clear()
            elif cmd == "begin" and arg == "document":
                state["text"].clear()
            elif cmd in ("begin","end") and arg == "abstract":
                state["abstract"] = cmd == "begin"; state["text"].clear()
            elif cmd == "abstract" and match.end() <= pos < i and path == target:
                state["abstract"] = True
            elif cmd in ("input","include","subfile","import","subimport") and arg:
                if cmd in ("import","subimport"):
                    second,i = group(clean,i + len(clean[i:]) - len(clean[i:].lstrip()))
                    arg = str(Path(arg)/second)
                suffix = Path(arg) if Path(arg).suffix else Path(arg+".tex")
                for start in ((path.parent,root) if cmd == "subimport" else (root,path.parent)):
                    candidate = (start / suffix).resolve()
                    if candidate.is_relative_to(root) and candidate.is_file():
                        if visit(candidate, parents | {path}):
                            return True
                        break
        return path == target
    found = visit(main,set())
    if not found:
        titles[:] = [""] * len(LEVELS); state.update(abstract=False,steps=0,text=[])
        visit(target,set())
    path = ["Abstract"] if state["abstract"] else [x for x in titles if x]
    # Some classes use a single \abstract{...} argument rather than an environment.
    for match in re.finditer(r"\\abstract\s*(?=\{)",SKIP.sub(lambda m:" "*len(m[0]),source[:pos])):
        if group(source,match.end())[1] > pos:
            path = ["Abstract"]
    before = "".join(state["text"])
    before = re.sub(r"\\(?:label|index|centering)\s*(?:\{[^{}]*\})?", "", before)
    paragraphs = re.split(r"\n[ \t\r]*\n|\\par\b", before)
    in_paragraph = paragraphs[-1].strip()
    following = re.split(r"\n[ \t\r]*\n|\\par\b",source[end:],maxsplit=1)[0].strip()
    final = not following or following.startswith(("\\end","\\section","\\subsection","\\par"))
    place = ("standalone" if final else "opening") if not in_paragraph else ("closing" if final else "middle")
    return {"headings":path, "role":classify(path), "paragraph":1 + sum(bool(p.strip()) for p in paragraphs[:-1]),
            "placement":place, "line":source[:pos].count("\n")+1,
            "linked":found}
