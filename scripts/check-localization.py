#!/usr/bin/env python3
"""
check-localization.py — the UIKit/SwiftUI shell's string tables, checked against
the code that reads them (D-088 mechanism, D-112 slices 2-3).

What it asserts, and fails loudly on:

  1. Every key the shell can look up exists in ALL FOUR Localizable.strings
     (en/fr/it/es). Keys are collected from:
       - OpenQ4_L("...") call sites, adjacent string literals concatenated;
       - OpenQ4_LS(@"...") call sites;
       - the kSettings table: each row's label and section;
       - SwiftUI literals that SwiftUI looks up as LocalizedStringKey
         (Button("..."), Text("..."), .accessibilityLabel("..."),
         LocalizedStringKey("..."));
       - App Intents strings (title / description / parameter title /
         requestValueDialog), which resolve against Localizable.strings.
     App Shortcut PHRASES are not covered: they localise through a separate
     AppShortcuts.strings, and ship English-only (D-112).
  2. en.lproj maps every key to itself (the key IS the English string).
  3. Every translation carries the same printf/NSString format specifiers, in
     the same order, as its key — a dropped %@ crashes or prints garbage.
  4. No table carries a key the code no longer reads (D-106: dead keys go).
  5. Each .strings file parses (plutil -lint).

Exit 0 and a one-line summary when green; exit 1 with every problem listed.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL_DIRS = [os.path.join(ROOT, "ios", "shell"), os.path.join(ROOT, "ios", "shell-visionos")]
LPROJ = os.path.join(ROOT, "ios", "Resources")
LANGS = ["en", "fr", "it", "es"]

C_STR = r'"((?:[^"\\\n]|\\.)*)"'


def c_unescape(s):
    # Only the escapes the shell's literals actually use.
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, "\\" + n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def strip_comments(src):
    # Remove /* */ and // comments without touching string literals.
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src[i] == '"':
            m = re.compile(C_STR).match(src, i)
            if not m:
                out.append(src[i])
                i += 1
            else:
                out.append(m.group(0))
                i = m.end()
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def literal_run(src, pos):
    """Concatenate adjacent C string literals starting at pos (after '(')."""
    parts = []
    lit = re.compile(r'\s*' + C_STR)
    while True:
        m = lit.match(src, pos)
        if not m:
            break
        parts.append(c_unescape(m.group(1)))
        pos = m.end()
    return "".join(parts) if parts else None


def collect_keys():
    keys = {}
    problems = []
    for d in SHELL_DIRS:
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name)
            if not name.endswith((".m", ".mm", ".swift")):
                continue
            src = strip_comments(open(path, encoding="utf-8").read())
            rel = os.path.relpath(path, ROOT)
            if name.endswith((".m", ".mm")):
                for m in re.finditer(r'\bOpenQ4_L\(', src):
                    k = literal_run(src, m.end())
                    if k is None:
                        continue  # OpenQ4_L(st->label) — covered by the table scan
                    keys.setdefault(k, rel)
                for m in re.finditer(r'\bOpenQ4_LS\(\s*@' + C_STR, src):
                    keys.setdefault(c_unescape(m.group(1)), rel)
                # kSettings rows: { "key", "label", cvar-or-NULL, "section", ...
                if "kSettings[]" in src:
                    body = src[src.index("kSettings[]"):]
                    body = body[:body.index("};")]
                    row = re.compile(r'\{\s*' + C_STR + r'\s*,\s*' + C_STR +
                                     r'\s*,\s*(?:NULL|' + C_STR + r')\s*,\s*' + C_STR)
                    n = 0
                    for m in row.finditer(body):
                        keys.setdefault(c_unescape(m.group(2)), rel + " kSettings.label")
                        keys.setdefault(c_unescape(m.group(4)), rel + " kSettings.section")
                        n += 1
                    if n < 20:
                        problems.append(f"{rel}: kSettings scan matched only {n} rows — parser broken?")
            else:
                for m in re.finditer(r'\b(?:Button|Text|accessibilityLabel|LocalizedStringKey|IntentDescription)\(\s*' + C_STR, src):
                    keys.setdefault(c_unescape(m.group(1)), rel)
                # App Intents metadata (D-112): titles, parameter titles, dialogs.
                for m in re.finditer(r'(?:LocalizedStringResource\s*=|\btitle:|requestValueDialog:)\s*' + C_STR, src):
                    keys.setdefault(c_unescape(m.group(1)), rel)
                # Button(cond ? "a" : "b")
                for m in re.finditer(r'\bButton\(\s*[\w.]+\s*\?\s*' + C_STR + r'\s*:\s*' + C_STR, src):
                    keys.setdefault(c_unescape(m.group(1)), rel)
                    keys.setdefault(c_unescape(m.group(2)), rel)
    return keys, problems


STR_ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def parse_strings(path):
    src = strip_comments(open(path, encoding="utf-8").read())
    table, dups = {}, []
    for m in STR_ENTRY.finditer(src):
        k, v = c_unescape(m.group(1)), c_unescape(m.group(2))
        if k in table:
            dups.append(k)
        table[k] = v
    return table, dups


SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSpaA%]')


def specs(s):
    return [x for x in SPEC.findall(s) if x != "%%"]


def main():
    keys, problems = collect_keys()
    tables = {}
    for lang in LANGS:
        path = os.path.join(LPROJ, f"{lang}.lproj", "Localizable.strings")
        r = subprocess.run(["plutil", "-lint", path], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append(f"{lang}: plutil -lint failed: {r.stdout.strip()} {r.stderr.strip()}")
        t, dups = parse_strings(path)
        for d in dups:
            problems.append(f"{lang}: duplicate key {d!r}")
        tables[lang] = t

    for k, where in sorted(keys.items()):
        for lang in LANGS:
            if k not in tables[lang]:
                problems.append(f"{lang}: MISSING {k!r} (read at {where})")
                continue
            v = tables[lang][k]
            if lang == "en" and v != k:
                problems.append(f"en: {k!r} maps to {v!r}; the key IS the English string")
            if specs(v) != specs(k):
                problems.append(f"{lang}: format specifiers differ for {k!r}: {specs(k)} vs {specs(v)}")
            if lang != "en" and not v.strip():
                problems.append(f"{lang}: empty translation for {k!r}")

    for lang in LANGS:
        for k in sorted(set(tables[lang]) - set(keys)):
            problems.append(f"{lang}: DEAD key {k!r} (no call site reads it)")

    if problems:
        print(f"check-localization: {len(problems)} problem(s)")
        for p in problems:
            print("  " + p)
        return 1
    same = {lang: sum(1 for k in keys if tables[lang][k] == k) for lang in LANGS[1:]}
    print(f"check-localization: OK — {len(keys)} keys in all of {', '.join(LANGS)}; "
          f"format specifiers match; untranslated-identical per language: {same}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
