#!/usr/bin/env python3
"""
JRI institutes watcher.

Scrapes the SingHealth Duke-NUS research institutes page and compares the
institutes found there against the `jri_institutes` list in
appfun/fct_helpers.R (which drives the app's JRI_Affiliation tagging).

If it finds an institute on the page whose acronym is NOT already in
jri_institutes, it adds the new entry (full name + acronym) to fct_helpers.R.
A scheduled GitHub Actions workflow then opens a PR with that change for review.
No extra state file is needed: jri_institutes itself is the source of truth, so
once a PR merges the institute is no longer "new" (idempotent).

Safety:
  * A sanity gate: if too few of the *known* institutes are found on the page,
    the extractor probably broke (HTML changed / JS-rendered). In that case we
    exit non-zero WITHOUT editing anything, so the workflow fails and alerts you
    instead of opening a garbage PR.
  * Auto-edits are only ever proposed via PR, never committed straight to main.

Debug: always writes the fetched HTML and parsed results under jri_debug/ so the
extractor can be calibrated from the workflow artifact (handy since the page
can't be fetched from every environment).

Usage:  python3 scripts/check_jri.py
Exit codes: 0 = ok (with or without changes), 2 = extraction sanity failed.
"""

import json
import os
import re
import sys
import urllib.request

URL = "https://www.singhealthdukenus.com.sg/research/overview-research-institutes"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPERS = os.path.join(ROOT, "appfun", "fct_helpers.R")
DEBUG_DIR = os.path.join(ROOT, "jri_debug")

# A parenthesised ACRONYM (>= 2 chars, mostly capitals) preceded by a run of
# Title-Case words / connectors -- e.g. "National Heart Research Institute
# Singapore (NHRIS)" or "...Institute of Precision Medicine (PRISM)". We capture
# the whole preceding phrase, then keep only those whose name mentions an
# Institute/Centre (filters out unrelated acronyms like "(FAQ)").
NAME_WORD = r"(?:[A-Z][\w'&.\-]*|of|in|and|for|the|on|to|&)"
PAIR_RE = re.compile(
    r"(" + NAME_WORD + r"(?:[ ]+" + NAME_WORD + r"){1,12})\s*"
    r"\(([A-Z][A-Z0-9][A-Z0-9\-]*)\)"
)
INSTITUTE_RE = re.compile(r"Institut", re.I)
# The real institutes are a <ul> of links right after this intro phrase; scoping
# to it avoids the nav/breadcrumb/footer noise elsewhere on the page.
SECTION_RE = re.compile(r"AMC Research Institutes.*?(<ul\b.*?</ul>)", re.I | re.S)
# Institute-named entities on the page that are NOT Joint Research Institutes
# (the "Academic Medicine Research Institute" is the AMC umbrella itself).
IGNORE_ACRONYMS = {"AMRI"}
# Reject support units that aren't Joint Research Institutes: the JRIs we track
# are all "...Institute(s)", but the page also lists centres, coordinating
# centres and committees.
EXCLUDE_RE = re.compile(r"Cent(?:re|er)|Committee|Coordinating", re.I)
# Site navigation / breadcrumb words that bleed into names after tag-stripping.
NAV_STOP_RE = re.compile(
    r"\b(?:About|Us|Home|Menu|MAIN|Back|Options|Search|Overview|Ethics|"
    r"Compliance|All|Contact|Login|Sitemap)\b", re.I)
TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")


def clean_name(name):
    """Strip navigation/breadcrumb bleed by splitting on nav words and keeping
    the last segment that still names an Institute."""
    segs = [s.strip(" -&,") for s in NAV_STOP_RE.split(name)]
    inst = [s for s in segs if INSTITUTE_RE.search(s)]
    return inst[-1] if inst else name.strip(" -&,")

# If fewer than this many already-known institutes are found on the page, assume
# the scrape broke rather than that the institutes vanished.
SANITY_MIN_KNOWN = 3


def fetch(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": ("Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36"),
        "Accept": "text/html,application/xhtml+xml",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", errors="replace")


def to_text(html):
    """Strip tags to plain text so name+acronym pairs split across elements
    still sit next to each other."""
    text = re.sub(r"(?is)<(script|style).*?</\1>", " ", html)
    text = TAG_RE.sub(" ", text)
    text = (text.replace("&amp;", "&").replace("&nbsp;", " ")
                .replace("&#39;", "'").replace("&rsquo;", "'"))
    return WS_RE.sub(" ", text).strip()


def extract_pairs(text):
    """Return {ACRONYM: Full Name} for institute/centre names found on the page."""
    out = {}
    for name, acr in PAIR_RE.findall(text):
        acr = acr.strip()
        name = WS_RE.sub(" ", name).strip(" ,.")
        if acr.upper() in IGNORE_ACRONYMS:
            continue  # known non-JRI (e.g. AMC umbrella)
        if not INSTITUTE_RE.search(name):
            continue  # not an Institute name
        if EXCLUDE_RE.search(name):
            continue  # a Centre / Committee / Coordinating unit, not a JRI
        out.setdefault(acr, clean_name(name))  # first/fullest name wins
    return out


def read_jri_institutes():
    """Parse the quoted entries of the jri_institutes <- c( ... ) vector."""
    src = open(HELPERS, encoding="utf-8").read()
    m = re.search(r"jri_institutes\s*<-\s*c\((.*?)\)", src, re.S)
    if not m:
        raise SystemExit("Could not find jri_institutes vector in fct_helpers.R")
    return re.findall(r'"([^"]+)"', m.group(1)), src


def add_to_helpers(src, additions):
    """Insert new "name"/"acronym" lines right after `jri_institutes <- c(`
    (order is irrelevant -- the list is only used for grepl matching)."""
    lines = []
    for name, acr in additions:
        lines.append(f'  "{name}",')
        lines.append(f'  "{acr}",')
    insert = "\n".join(lines) + "\n"
    return re.sub(r"(jri_institutes\s*<-\s*c\(\n)", r"\1" + insert, src, count=1)


def main():
    os.makedirs(DEBUG_DIR, exist_ok=True)
    try:
        html = fetch(URL)
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: could not fetch {URL}: {e}")
        return 2
    open(os.path.join(DEBUG_DIR, "page.html"), "w", encoding="utf-8").write(html)

    # Prefer the institutes <ul> that follows the "AMC Research Institutes"
    # intro; fall back to the whole page if that structure isn't found (the
    # exclusion filters + ignore list still guard the fallback).
    m = SECTION_RE.search(html)
    if m:
        print("Scoped to the AMC Research Institutes list section.")
        pairs = extract_pairs(to_text(m.group(1)))
    else:
        print("Institutes list section not found; scanning whole page.")
        pairs = extract_pairs(to_text(html))
    json.dump(pairs, open(os.path.join(DEBUG_DIR, "extracted.json"), "w"),
              indent=2, sort_keys=True)
    print(f"Extracted {len(pairs)} institute(s) from the page:")
    for acr, name in sorted(pairs.items()):
        print(f"  {acr}: {name}")

    entries, src = read_jri_institutes()
    known_upper = {e.upper() for e in entries}

    # Sanity gate: did we re-find enough of the institutes we already track?
    found_known = [a for a in pairs if a.upper() in known_upper]
    if len(found_known) < SANITY_MIN_KNOWN:
        print(f"\nFAIL: extraction sanity check -- only {len(found_known)} known "
              f"institute(s) found on the page (need >= {SANITY_MIN_KNOWN}). The "
              f"page layout likely changed or is JS-rendered; not editing. See "
              f"the jri_debug artifact to recalibrate the extractor.")
        return 2

    # New = acronym on the page that isn't already an entry in jri_institutes.
    new = [(name, acr) for acr, name in sorted(pairs.items())
           if acr.upper() not in known_upper]

    if not new:
        print("\nNo new JRI institutes. jri_institutes is up to date.")
        return 0

    print("\nNew institute(s) not in jri_institutes:")
    for name, acr in new:
        print(f"  + {name} ({acr})")
    open(HELPERS, "w", encoding="utf-8").write(add_to_helpers(src, new))

    body = ["Detected institute(s) on the SingHealth Duke-NUS research institutes",
            f"page ({URL}) that are not yet in `jri_institutes`:", ""]
    body += [f"- **{name}** (`{acr}`)" for name, acr in new]
    body += ["", "Review that these are genuine Joint Research Institutes before merging."]
    open(os.path.join(DEBUG_DIR, "pr_body.md"), "w").write("\n".join(body))
    print("\nUpdated appfun/fct_helpers.R.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
