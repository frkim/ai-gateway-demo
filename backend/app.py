"""
AI Gateway demo — Foundry multi-agent backend.

Exposes a tiny HTTP API the browser demo calls to run 5 multi-agent use cases
against REAL Azure AI Foundry Agent Service agents. Authenticates to the Foundry
project with a managed identity (DefaultAzureCredential). One agent uses the
Azure AI Search ("Foundry IQ") tool grounded on the enterprise-kb index.

Env vars:
  PROJECT_ENDPOINT        https://<acct>.services.ai.azure.com/api/projects/<proj>
  MODEL_DEPLOYMENT_NAME   chat model deployment for the agents (e.g. gpt-5-mini)
  SEARCH_CONNECTION_NAME  Foundry project connection to Azure AI Search
  SEARCH_INDEX_NAME       Azure AI Search index (default: enterprise-kb)
"""
import os
import logging
from typing import Optional

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.agents.models import AzureAISearchTool, ListSortOrder

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("agents-backend")

PROJECT_ENDPOINT = os.environ["PROJECT_ENDPOINT"]
# The Foundry Assistants runtime is used for all agents; gpt-4.1-mini is reliable
# there (gpt-5 reasoning models don't return assistant text consistently and can't
# use the classic azure_ai_search tool).
MODEL = os.environ.get("MODEL_DEPLOYMENT_NAME", "gpt-4.1-mini")
SEARCH_MODEL = os.environ.get("SEARCH_MODEL_DEPLOYMENT_NAME", "gpt-4.1-mini")
SEARCH_CONNECTION_NAME = os.environ.get("SEARCH_CONNECTION_NAME", "enterprise-search")
SEARCH_INDEX = os.environ.get("SEARCH_INDEX_NAME", "enterprise-kb")

# ---- Agent definitions -------------------------------------------------------
AGENT_DEFS = {
    "kb-concierge": {
        "instructions": (
            "You are the Contoso enterprise knowledge concierge. Answer ONLY from the "
            "enterprise knowledge base retrieved by your Azure AI Search tool. Be concise "
            "and cite the source sections. If the answer is not in the knowledge base, say "
            "you do not have that information."
        ),
        "search": True,
    },
    "policy-analyst": {
        "instructions": (
            "You are a meticulous policy analyst. Given retrieved policy text and a question, "
            "compare and explain the relevant policies clearly, note conditions, limits and "
            "exceptions, and present the answer as short bullet points."
        ),
        "search": False,
    },
    "ops-router": {
        "instructions": (
            "You are a triage router for an enterprise assistant. Classify the user's request "
            "into exactly one category and reply with ONLY the category token on the first line, "
            "then one short sentence explaining why. Categories: KNOWLEDGE (answerable from the "
            "enterprise knowledge base), DRAFTING (write/compose content), OTHER."
        ),
        "search": False,
    },
    "doc-writer": {
        "instructions": (
            "You are a professional enterprise writer. Produce clear, well-structured content "
            "(email, summary, or brief) grounded in any facts provided to you. Keep a "
            "professional tone and do not invent policy details."
        ),
        "search": False,
    },
    "qa-reviewer": {
        "instructions": (
            "You are a critical reviewer. Review the draft for accuracy against the provided "
            "facts, clarity and tone. Return the improved final version first, then a short "
            "'Reviewer notes:' list of the changes you made."
        ),
        "search": False,
    },
}

# ---- Use cases (orchestrations) ---------------------------------------------
USE_CASES = [
    {
        "id": "kb-concierge",
        "title": "1 · Knowledge concierge (RAG agent + Foundry IQ)",
        "desc": "A single Foundry agent grounded on Azure AI Search (enterprise-kb) answers with citations.",
        "sample": "What is our enterprise return policy and how are refunds issued?",
        "agents": ["kb-concierge"],
    },
    {
        "id": "policy-compare",
        "title": "2 · Policy compare (retriever → analyst)",
        "desc": "kb-concierge retrieves grounded facts, then policy-analyst compares and explains them.",
        "sample": "Compare our standard vs premium support SLAs.",
        "agents": ["kb-concierge", "policy-analyst"],
    },
    {
        "id": "triage-route",
        "title": "3 · Triage & route (router → specialist)",
        "desc": "ops-router classifies the request, then routes it to the knowledge or writer agent.",
        "sample": "Draft a friendly reminder to employees that MFA is mandatory.",
        "agents": ["ops-router", "kb-concierge | doc-writer"],
    },
    {
        "id": "draft-review",
        "title": "4 · Draft & review (writer → reviewer)",
        "desc": "doc-writer drafts content, then qa-reviewer critiques and finalizes it.",
        "sample": "Write a short customer email explaining our 30-day return policy.",
        "agents": ["doc-writer", "qa-reviewer"],
    },
    {
        "id": "research-brief",
        "title": "5 · Research brief (retriever → writer → reviewer)",
        "desc": "kb-concierge gathers grounded facts, doc-writer drafts a brief, qa-reviewer polishes it.",
        "sample": "Prepare a one-paragraph brief on our security and data-privacy posture.",
        "agents": ["kb-concierge", "doc-writer", "qa-reviewer"],
    },
]

app = FastAPI(title="AI Gateway — Foundry multi-agent backend")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"],
)

_project: Optional[AIProjectClient] = None
_agent_ids: dict = {}


def project() -> AIProjectClient:
    global _project
    if _project is None:
        _project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())
    return _project


def _search_connection_id() -> Optional[str]:
    try:
        conn = project().connections.get(name=SEARCH_CONNECTION_NAME)
        return conn.id
    except Exception as e:  # pragma: no cover
        log.warning("Could not resolve search connection '%s': %s", SEARCH_CONNECTION_NAME, e)
        try:
            for c in project().connections.list():
                if getattr(c, "name", "") == SEARCH_CONNECTION_NAME:
                    return c.id
        except Exception as e2:
            log.warning("connections.list failed: %s", e2)
    return None


def ensure_agents() -> dict:
    """Create the 5 agents if they don't already exist (idempotent by name)."""
    agents = project().agents
    existing = {}
    try:
        for a in agents.list_agents():
            existing[a.name] = a.id
    except Exception as e:
        log.warning("list_agents failed: %s", e)

    search_conn_id = _search_connection_id()
    for name, spec in AGENT_DEFS.items():
        if name in existing:
            _agent_ids[name] = existing[name]
            continue
        tools = None
        tool_resources = None
        if spec["search"] and search_conn_id:
            ai_search = AzureAISearchTool(index_connection_id=search_conn_id, index_name=SEARCH_INDEX)
            tools = ai_search.definitions
            tool_resources = ai_search.resources
        try:
            model = SEARCH_MODEL if spec["search"] else MODEL
            kwargs = dict(model=model, name=name, instructions=spec["instructions"])
            if tools:
                kwargs["tools"] = tools
                kwargs["tool_resources"] = tool_resources
            agent = agents.create_agent(**kwargs)
            _agent_ids[name] = agent.id
            log.info("created agent %s -> %s", name, agent.id)
        except Exception as e:
            log.error("create_agent %s failed: %s", name, e)
    return _agent_ids


def run_agent(name: str, prompt: str):
    """Run one agent on a prompt; return (text, citations)."""
    agents = project().agents
    agent_id = _agent_ids.get(name)
    if not agent_id:
        ensure_agents()
        agent_id = _agent_ids.get(name)
    if not agent_id:
        return (f"[agent '{name}' unavailable]", [])

    thread = agents.threads.create()
    agents.messages.create(thread_id=thread.id, role="user", content=prompt)
    run = agents.runs.create_and_process(thread_id=thread.id, agent_id=agent_id)
    if run.status == "failed":
        return (f"[run failed: {getattr(run, 'last_error', '')}]", [])

    text = ""
    citations = []
    for msg in agents.messages.list(thread_id=thread.id, order=ListSortOrder.ASCENDING):
        if msg.role != "assistant":
            continue
        for part in (msg.content or []):
            t = getattr(part, "text", None)
            if not t:
                continue
            text = t.value if hasattr(t, "value") else str(t)
            for ann in (getattr(t, "annotations", None) or []):
                uc = getattr(ann, "url_citation", None)
                if uc:
                    citations.append({"title": getattr(uc, "title", ""), "url": getattr(uc, "url", "")})
                else:
                    title = getattr(getattr(ann, "file_citation", None), "file_id", "") or getattr(ann, "text", "")
                    if title:
                        citations.append({"title": str(title), "url": ""})
    try:
        agents.threads.delete(thread.id)
    except Exception:
        pass
    return (text, citations)


class InvokeReq(BaseModel):
    usecase: str
    input: str


@app.on_event("startup")
def _startup():
    try:
        ensure_agents()
    except Exception as e:
        log.error("ensure_agents on startup failed: %s", e)


@app.get("/health")
def health():
    return {"ok": True, "agents": list(_agent_ids.keys())}


@app.get("/api/usecases")
def usecases():
    return {"usecases": USE_CASES}


@app.post("/api/invoke")
def invoke(req: InvokeReq):
    text = (req.input or "").strip()
    steps = []
    citations = []

    if req.usecase == "kb-concierge":
        ans, cits = run_agent("kb-concierge", text)
        steps.append({"agent": "kb-concierge", "output": ans})
        citations = cits
        answer = ans

    elif req.usecase == "policy-compare":
        facts, cits = run_agent("kb-concierge", f"Retrieve the relevant policy details for: {text}")
        steps.append({"agent": "kb-concierge", "output": facts})
        citations = cits
        answer, _ = run_agent("policy-analyst", f"Question: {text}\n\nRetrieved policy text:\n{facts}")
        steps.append({"agent": "policy-analyst", "output": answer})

    elif req.usecase == "triage-route":
        routing, _ = run_agent("ops-router", text)
        steps.append({"agent": "ops-router", "output": routing})
        label = routing.strip().splitlines()[0].upper() if routing.strip() else "OTHER"
        if "KNOWLEDGE" in label:
            answer, citations = run_agent("kb-concierge", text)
            steps.append({"agent": "kb-concierge", "output": answer})
        elif "DRAFTING" in label:
            answer, _ = run_agent("doc-writer", text)
            steps.append({"agent": "doc-writer", "output": answer})
        else:
            answer, _ = run_agent("kb-concierge", text)
            steps.append({"agent": "kb-concierge", "output": answer})

    elif req.usecase == "draft-review":
        draft, _ = run_agent("doc-writer", text)
        steps.append({"agent": "doc-writer", "output": draft})
        answer, _ = run_agent("qa-reviewer", f"Task: {text}\n\nDraft to review:\n{draft}")
        steps.append({"agent": "qa-reviewer", "output": answer})

    elif req.usecase == "research-brief":
        facts, cits = run_agent("kb-concierge", f"Gather the key facts needed to answer: {text}")
        steps.append({"agent": "kb-concierge", "output": facts})
        citations = cits
        draft, _ = run_agent("doc-writer", f"Using ONLY these facts, {text}\n\nFacts:\n{facts}")
        steps.append({"agent": "doc-writer", "output": draft})
        answer, _ = run_agent("qa-reviewer", f"Task: {text}\n\nDraft to review:\n{draft}")
        steps.append({"agent": "qa-reviewer", "output": answer})

    else:
        return {"error": f"unknown usecase '{req.usecase}'"}

    return {"usecase": req.usecase, "answer": answer, "steps": steps, "citations": citations}
