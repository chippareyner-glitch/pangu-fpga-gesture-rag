#!/usr/bin/env python3
"""
search_rag.py
-------------
Lightweight, Zero-Dependency RAG Retrieval Engine for Pangu FPGA Gesture Knowledge Base.
Supports:
- Keyword & Token-Aware Hybrid Scoring
- Chunk Metadata Extraction
- Interactive CLI & JSON API Output
"""

import os
import sys
import re
import json

KB_FILE = os.path.join(os.path.dirname(__file__), "rag_docs", "RAG_KNOWLEDGE_BASE.md")

def load_chunks(kb_path=KB_FILE):
    if not os.path.exists(kb_path):
        print(f"[!] Error: Knowledge base file not found at {kb_path}")
        return []

    with open(kb_path, "r", encoding="utf-8") as f:
        content = f.read()

    raw_chunks = content.split("## [CHUNK_ID: ")
    chunks = []
    for rc in raw_chunks[1:]:
        header_end = rc.find("]")
        chunk_id = rc[:header_end].strip()
        body = rc[header_end+1:].strip()

        # Parse category & keywords
        cat_match = re.search(r"\* \*\*Category\*\*:\s*(.*)", body)
        kw_match = re.search(r"\* \*\*Keywords\*\*:\s*(.*)", body)
        hw_match = re.search(r"\* \*\*Target Hardware\*\*:\s*(.*)", body)
        sum_match = re.search(r"\* \*\*Summary\*\*:\s*(.*)", body)
        content_match = re.search(r"\* \*\*Content\*\*:\s*(.*)", body, re.DOTALL)

        chunks.append({
            "chunk_id": chunk_id,
            "category": cat_match.group(1).strip() if cat_match else "",
            "keywords": kw_match.group(1).strip() if kw_match else "",
            "target_hardware": hw_match.group(1).strip() if hw_match else "",
            "summary": sum_match.group(1).strip() if sum_match else "",
            "content": content_match.group(1).strip() if content_match else body,
            "raw": rc
        })
    return chunks

def search(query, top_k=3, json_output=False):
    chunks = load_chunks()
    if not chunks:
        return

    # Clean query tokens
    query_tokens = [t.lower() for t in re.split(r"\s+|,|;|/|、|，", query) if len(t.strip()) > 1]
    
    scored_chunks = []
    for c in chunks:
        score = 0.0
        text_corpus = f"{c['chunk_id']} {c['category']} {c['keywords']} {c['summary']} {c['content']}".lower()

        for token in query_tokens:
            # Keyword exact match
            if token in c['keywords'].lower():
                score += 5.0
            # Summary match
            if token in c['summary'].lower():
                score += 3.0
            # General occurrences
            occurrences = text_corpus.count(token)
            score += min(occurrences * 1.0, 6.0)

        if score > 0:
            scored_chunks.append((score, c))

    scored_chunks.sort(key=lambda x: x[0], reverse=True)
    results = scored_chunks[:top_k]

    if json_output:
        out = [{"score": s, "chunk_id": c["chunk_id"], "category": c["category"], "summary": c["summary"], "content": c["content"]} for s, c in results]
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return

    print("=" * 70)
    print(f" Query: '{query}' | Top {len(results)} Matches Found")
    print("=" * 70)

    if not results:
        print("[!] No direct matches found. Try queries like: 'Click-Hold', 'YCrCb', 'INT8', 'BNN', '双通道'")
        return

    for idx, (score, c) in enumerate(results, 1):
        print(f"\n[{idx}] [{c['chunk_id']}] (Relevance Score: {score:.1f})")
        print(f" Category : {c['category']}")
        print(f" Hardware : {c['target_hardware']}")
        print(f" Keywords : {c['keywords']}")
        print(f" Summary  : {c['summary']}")
        print("-" * 70)
        print(f"{c['content'][:350]}...\n")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python search_rag.py <query> [--top-k N] [--json]")
        print("Example: python search_rag.py '大拇指扣动双通道' --top-k 2")
        sys.exit(1)

    q = sys.argv[1]
    k = 3
    is_json = "--json" in sys.argv
    if "--top-k" in sys.argv:
        try:
            k = int(sys.argv[sys.argv.index("--top-k") + 1])
        except (ValueError, IndexError):
            k = 3

    search(q, top_k=k, json_output=is_json)
