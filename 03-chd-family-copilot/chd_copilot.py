#!/usr/bin/env python
# coding: utf-8

"""
CHD Family Copilot
Research prototype - not a medical device.

Core capabilities
-----------------
- Conversation-aware longitudinal patient context
- Local intent detection (no API call for hello/thanks/bye/help)
- Safety triage agent
- Missing-information detector
- Dynamic multi-agent routing
- Specialized education, exercise, nutrition, surgery, QoL and caregiver agents
- PubMed evidence retrieval with caching
- Curated local guideline retrieval
- Explainable provider matching
- Evidence/hallucination verification
- Governance metadata
"""

import json
import os
import re
from datetime import datetime
from pathlib import Path

from Bio import Entrez, Medline
from litellm import completion


# ============================================================
# CONFIGURATION
# ============================================================

MODEL_NAME = os.getenv("CHD_COPILOT_MODEL", "openai/gpt-4.1-mini")
PROVIDER_FILE = Path(os.getenv("CHD_PROVIDER_FILE", "providers_enriched.json"))
GUIDELINE_FILE = Path(os.getenv("CHD_GUIDELINE_FILE", "guidelines.json"))
MAX_PUBMED_RESULTS = int(os.getenv("CHD_MAX_PUBMED_RESULTS", "3"))
MAX_SPECIALIZED_AGENTS = int(os.getenv("CHD_MAX_SPECIALIZED_AGENTS", "2"))

Entrez.email = os.getenv("NCBI_EMAIL", "your_email@example.com")


# ============================================================
# LLM HELPER
# ============================================================

def ask_agent(system_prompt, user_prompt, temperature=0.2):
    if not os.getenv("OPENAI_API_KEY"):
        raise RuntimeError(
            "OPENAI_API_KEY is not configured. "
            "Set it in the environment before starting the app."
        )

    response = completion(
        model=MODEL_NAME,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=temperature,
    )

    return response.choices[0].message.content


# ============================================================
# LOCAL INTENT AGENT — NO API CALL
# ============================================================

def detect_conversation_intent(question):
    text = " ".join(question.lower().strip().split())

    if not text:
        return "empty"

    greetings = {
        "hi", "hello", "hey", "hi there", "hello there",
        "good morning", "good afternoon", "good evening"
    }

    thanks = {
        "thanks", "thank you", "thank you so much", "thx"
    }

    goodbye = {
        "bye", "goodbye", "see you", "see you later"
    }

    help_phrases = {
        "help", "what can you do", "how can you help",
        "what does this app do", "what does this copilot do"
    }

    if text in greetings:
        return "greeting"
    if text in thanks:
        return "thanks"
    if text in goodbye:
        return "goodbye"
    if text in help_phrases:
        return "capabilities"

    return "clinical"


def local_conversation_response(intent):
    if intent == "greeting":
        return (
            "Hello 👋 I’m the **CHD Family Copilot**. I can help with congenital "
            "heart disease education, exercise and cardiac rehabilitation, nutrition "
            "and growth, surgery questions, quality of life, caregiver support, "
            "evidence, and care navigation. What would you like to discuss?"
        )

    if intent == "thanks":
        return (
            "You’re welcome. If you have another CHD question, you can continue "
            "the same conversation and I’ll use the patient context we’ve already discussed."
        )

    if intent == "goodbye":
        return "Take care. You can start a new patient conversation anytime from the sidebar."

    if intent == "capabilities":
        return (
            "I can remember patient context during this session, route questions to "
            "specialized CHD agents, screen for safety concerns, retrieve PubMed evidence, "
            "use locally curated guidelines, match relevant providers, flag missing "
            "information, and show an AI governance summary."
        )

    return ""


# ============================================================
# DETERMINISTIC CONTEXT HELPERS
# ============================================================

DIAGNOSIS_KEYWORDS = {
    "Tetralogy of Fallot": ["tetralogy of fallot", "tof"],
    "Fontan Circulation": ["fontan", "single ventricle"],
    "Hypoplastic Left Heart Syndrome": ["hlhs", "hypoplastic left heart syndrome"],
    "Transposition of the Great Arteries": [
        "transposition of the great arteries", "tga", "arterial switch"
    ],
    "Atrioventricular Septal Defect": [
        "atrioventricular septal defect", "avsd", "av canal", "complete canal"
    ],
    "Ventricular Septal Defect": ["ventricular septal defect", "vsd"],
    "Atrial Septal Defect": ["atrial septal defect", "asd"],
    "Coarctation of the Aorta": ["coarctation of the aorta", "coarctation", "coa"],
    "Ebstein Anomaly": ["ebstein anomaly", "ebstein"],
    "Norwood Palliation": ["norwood"],
    "Congenital Heart Disease": ["congenital heart disease", "chd"],
}


def identify_diagnosis(question):
    text = question.lower()
    for diagnosis, keywords in DIAGNOSIS_KEYWORDS.items():
        if any(keyword in text for keyword in keywords):
            return diagnosis
    return "Unknown"


def identify_activity(question):
    text = question.lower()

    activities = {
        "Soccer": ["soccer", "football"],
        "Swimming": ["swimming", "swim"],
        "Basketball": ["basketball"],
        "Running": ["running", "run", "jogging"],
        "Cycling": ["cycling", "biking", "bike"],
        "Gym or Strength Training": [
            "gym", "weightlifting", "weight lifting", "weights", "strength training"
        ],
        "Dance": ["dance", "dancing"],
        "Physical Education": ["physical education", "pe class", "p.e."],
        "Competitive Sports": ["competitive sports", "sports team"],
        "General Play": ["playing", "play", "playground"],
    }

    for activity, keywords in activities.items():
        if any(keyword in text for keyword in keywords):
            return activity

    return None


def extract_age_locally(question):
    patterns = [
        r"\b(\d{1,2})\s*[- ]?year[- ]?old\b",
        r"\b(\d{1,2})\s*years?\s*old\b",
        r"\bage\s*(\d{1,2})\b",
    ]
    text = question.lower()
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            age = int(match.group(1))
            if 0 <= age <= 100:
                return age
    return None


def extract_sex_locally(question):
    text = question.lower()
    if any(term in text for term in ["daughter", "girl", "female", "she ", "her "]):
        return "female"
    if any(term in text for term in ["son", "boy", "male", "he ", "his "]):
        return "male"
    return None


# ============================================================
# CONVERSATION MEMORY / LONGITUDINAL PATIENT PROFILE
# ============================================================

def conversation_text(history=None, max_messages=8):
    if not history:
        return "No previous conversation."

    recent = history[-max_messages:]
    return "\n".join(
        f"{message.get('role', 'unknown')}: {message.get('content', '')}"
        for message in recent
    )


def merge_patient_context(old_context, new_context):
    merged = dict(old_context or {})

    for key, value in (new_context or {}).items():
        if value in [None, "", "Unknown", [], {}]:
            continue

        if key in {"symptoms", "procedures"}:
            previous = merged.get(key, [])
            if not isinstance(previous, list):
                previous = [previous]
            if not isinstance(value, list):
                value = [value]
            merged[key] = list(dict.fromkeys(previous + value))
        else:
            merged[key] = value

    merged["last_updated"] = datetime.now().isoformat(timespec="seconds")
    return merged


def extract_context(question, history=None, patient_context=None):
    """
    Hybrid context extraction:
    1. deterministic extraction anchors high-confidence CHD facts
    2. one LLM call adds symptoms, procedures and multi-topic interpretation
    3. old longitudinal context is never overwritten by Unknown/null values
    """

    deterministic = {
        "age": extract_age_locally(question),
        "sex": extract_sex_locally(question),
        "diagnosis": identify_diagnosis(question),
        "repair_status": None,
        "procedures": [],
        "activity": identify_activity(question),
        "symptoms": [],
        "topics": [],
        "caregiver_question": False,
    }

    system_prompt = """
You are the structured context agent for a congenital heart disease family copilot.

Return VALID JSON ONLY. Do not provide medical advice.

Use the previous patient context for follow-up questions with pronouns or omitted
diagnoses, such as "Can she play soccer?" or "What about swimming?"

Do not invent facts.

Return exactly:
{
  "age": null,
  "sex": null,
  "diagnosis": "Unknown",
  "repair_status": null,
  "procedures": [],
  "activity": null,
  "symptoms": [],
  "topics": [],
  "caregiver_question": false
}

Allowed topics:
education
exercise
nutrition
surgery
qol
caregiver

A question may have multiple topics. Use "qol" for school, social functioning,
emotional well-being or daily functioning. Use "caregiver" when the primary
concern is the parent/caregiver. Use "exercise" for play, sports, physical
activity, exercise intolerance or fatigue with activity.
"""

    user_prompt = f"""
PREVIOUS PATIENT CONTEXT:
{json.dumps(patient_context or {}, indent=2)}

RECENT CONVERSATION:
{conversation_text(history)}

CURRENT QUESTION:
{question}
"""

    llm_context = {}

    try:
        raw = ask_agent(system_prompt, user_prompt, temperature=0)
        raw = raw.strip()
        raw = re.sub(r"^```(?:json)?", "", raw)
        raw = re.sub(r"```$", "", raw)
        llm_context = json.loads(raw)
    except Exception:
        llm_context = {}

    # High-confidence deterministic values win when explicitly present.
    combined = dict(llm_context or {})

    for field in ["age", "sex", "diagnosis", "activity"]:
        value = deterministic[field]
        if value not in [None, "", "Unknown"]:
            combined[field] = value

    # If current extraction is Unknown but memory has a diagnosis, preserve memory.
    if combined.get("diagnosis") in [None, "", "Unknown"]:
        prior_diagnosis = (patient_context or {}).get("diagnosis")
        if prior_diagnosis:
            combined["diagnosis"] = prior_diagnosis

    if combined.get("age") is None and (patient_context or {}).get("age") is not None:
        combined["age"] = patient_context["age"]

    if combined.get("sex") in [None, ""] and (patient_context or {}).get("sex"):
        combined["sex"] = patient_context["sex"]

    if combined.get("activity") in [None, ""] and deterministic.get("activity"):
        combined["activity"] = deterministic["activity"]

    topics = combined.get("topics") or []
    if isinstance(topics, str):
        topics = [topics]

    allowed_topics = {"education", "exercise", "nutrition", "surgery", "qol", "caregiver"}
    topics = [t for t in topics if t in allowed_topics]

    # Deterministic topic enrichment to prevent obvious misses.
    lower = question.lower()

    if any(term in lower for term in [
        "soccer", "football", "basketball", "swim", "swimming", "exercise",
        "sport", "playing", "play", "running", "physical activity", "gets tired",
        "tires easily", "cannot keep up", "exercise intolerance"
    ]):
        if "exercise" not in topics:
            topics.append("exercise")

    if any(term in lower for term in [
        "nutrition", "feeding", "appetite", "weight gain", "poor weight",
        "growth", "calorie", "diet", "food", "tube feeding"
    ]):
        if "nutrition" not in topics:
            topics.append("nutrition")

    if any(term in lower for term in [
        "surgery", "operation", "surgeon", "reoperation", "valve replacement"
    ]):
        if "surgery" not in topics:
            topics.append("surgery")

    if any(term in lower for term in [
        "school", "anxiety", "anxious", "sad", "upset", "friend", "social",
        "quality of life", "feels different", "bully", "confidence"
    ]):
        if "qol" not in topics:
            topics.append("qol")

    if any(term in lower for term in [
        "caregiver", "i am overwhelmed", "i'm overwhelmed", "burnout",
        "family support", "sibling", "prepare for surgery", "prepare for clinic"
    ]):
        if "caregiver" not in topics:
            topics.append("caregiver")

    if not topics:
        topics = ["education"]

    combined["topics"] = list(dict.fromkeys(topics))
    combined.setdefault("procedures", [])
    combined.setdefault("symptoms", [])
    combined.setdefault("repair_status", None)
    combined.setdefault("caregiver_question", False)

    return combined


# ============================================================
# SAFETY AGENT — NO API CALL
# ============================================================

def safety_agent(question, context=None):
    text = question.lower()

    emergency_terms = [
        "fainted", "fainting", "syncope", "passed out", "unresponsive",
        "cardiac arrest", "cannot breathe", "severe difficulty breathing",
        "blue lips", "turning blue", "cyanosis", "severe chest pain"
    ]

    urgent_terms = [
        "chest pain", "palpitations", "gets tired", "tires easily",
        "very tired", "fatigue during play", "shortness of breath",
        "exercise intolerance", "poor exercise tolerance", "dizziness",
        "cannot keep up", "worsening fatigue"
    ]

    emergency_hits = [term for term in emergency_terms if term in text]
    urgent_hits = [term for term in urgent_terms if term in text]

    if emergency_hits:
        return {
            "level": "EMERGENCY",
            "triggers": emergency_hits,
            "human_review": True,
        }

    if urgent_hits:
        return {
            "level": "URGENT",
            "triggers": urgent_hits,
            "human_review": True,
        }

    return {
        "level": "ROUTINE",
        "triggers": [],
        "human_review": False,
    }


# ============================================================
# MISSING INFORMATION AGENT — NO API CALL
# ============================================================

TOPIC_REQUIRED_INFORMATION = {
    "exercise": ["age", "diagnosis", "activity"],
    "nutrition": ["age", "diagnosis"],
    "surgery": ["diagnosis"],
    "qol": ["age", "diagnosis"],
    "caregiver": ["diagnosis"],
    "education": ["diagnosis"],
}


def detect_missing_information(context):
    required = set()

    for topic in context.get("topics", ["education"]):
        required.update(TOPIC_REQUIRED_INFORMATION.get(topic, []))

    missing = []
    for field in sorted(required):
        value = context.get(field)
        if value in [None, "", "Unknown", [], {}]:
            missing.append(field)

    return missing


# ============================================================
# PUBMED EVIDENCE AGENT
# ============================================================

TOPIC_SEARCH_TERMS = {
    "exercise": (
        "exercise OR physical activity OR sports OR cardiac rehabilitation "
        "OR exercise training OR exercise tolerance"
    ),
    "nutrition": (
        "nutrition OR feeding OR growth OR weight gain OR malnutrition OR diet"
    ),
    "surgery": (
        "surgery OR cardiac surgery OR reoperation OR surgical outcomes"
    ),
    "qol": (
        "quality of life OR psychosocial OR school OR anxiety OR mental health"
    ),
    "caregiver": (
        "caregiver OR parent stress OR family support OR caregiver burden "
        "OR psychosocial support"
    ),
    "education": (
        "patient education OR family education OR long-term follow-up"
    ),
}


def search_pubmed(query, max_results=MAX_PUBMED_RESULTS):
    handle = Entrez.esearch(
        db="pubmed",
        term=query,
        retmax=max_results,
        sort="relevance",
    )
    results = Entrez.read(handle)
    handle.close()
    return results.get("IdList", [])


def fetch_articles(id_list):
    if not id_list:
        return []

    handle = Entrez.efetch(
        db="pubmed",
        id=",".join(id_list),
        rettype="medline",
        retmode="text",
    )
    records = list(Medline.parse(handle))
    handle.close()
    return records


class EvidenceAgent:
    def __init__(self):
        self.cache = {}

    def search(self, diagnosis, topic):
        condition = diagnosis if diagnosis != "Unknown" else "congenital heart disease"
        topic_terms = TOPIC_SEARCH_TERMS.get(topic, TOPIC_SEARCH_TERMS["education"])
        query = f'"{condition}" AND ({topic_terms})'

        if query in self.cache:
            return self.cache[query]

        try:
            pmids = search_pubmed(query, MAX_PUBMED_RESULTS)
            articles = fetch_articles(pmids)
        except Exception:
            articles = []

        self.cache[query] = articles
        return articles


evidence_agent = EvidenceAgent()


def summarize_evidence(articles):
    if not articles:
        return (
            "No directly relevant PubMed records were retrieved for this turn. "
            "The response should acknowledge that limitation."
        )

    summaries = []

    for article in articles:
        pmid = article.get("PMID", "Not available")
        title = article.get("TI", "Title unavailable")
        authors = article.get("AU", [])
        year = article.get("DP", "")
        abstract = re.sub(r"\s+", " ", article.get("AB", "")).strip()

        summaries.append(
            f"""
PMID: {pmid}
Title: {title}
Authors: {", ".join(authors[:4])}
Publication date: {year}
Abstract excerpt: {abstract[:700] if abstract else "Abstract unavailable."}
""".strip()
        )

    return "\n\n---\n\n".join(summaries)


# ============================================================
# CURATED GUIDELINE AGENT
# ============================================================

def load_guidelines(filename=GUIDELINE_FILE):
    path = Path(filename)

    if not path.exists():
        return []

    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


GUIDELINE_DATABASE = load_guidelines()


def retrieve_guidelines(diagnosis, topics, max_results=3):
    if not GUIDELINE_DATABASE:
        return []

    terms = set()

    if diagnosis and diagnosis != "Unknown":
        terms.update(re.findall(r"[a-zA-Z]{4,}", diagnosis.lower()))

    for topic in topics:
        terms.add(topic.lower())

    scored = []

    for guideline in GUIDELINE_DATABASE:
        searchable = " ".join([
            str(guideline.get("title", "")),
            str(guideline.get("organization", "")),
            str(guideline.get("text", "")),
            " ".join(guideline.get("topics", [])),
        ]).lower()

        score = sum(1 for term in terms if term in searchable)

        if score:
            scored.append((score, guideline))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [g for _, g in scored[:max_results]]


def format_guidelines(guidelines):
    if not guidelines:
        return "No locally curated guideline summary was available for this question."

    return "\n\n---\n\n".join(
        f"""
Title: {g.get("title", "Not listed")}
Organization: {g.get("organization", "Not listed")}
Year: {g.get("year", "Not listed")}
Reviewed summary: {g.get("text", "")}
Source: {g.get("url", "")}
""".strip()
        for g in guidelines
    )


# ============================================================
# SPECIALIZED CLINICAL/FAMILY AGENTS
# ============================================================

def education_agent(question, diagnosis, evidence):
    system_prompt = """
You are the Pediatric CHD Education Agent.

Provide concise, family-friendly, evidence-informed congenital heart disease
education. Never diagnose, prescribe, determine surgery, or replace the care team.
Acknowledge uncertainty.

Return:
# Educational Perspective
## What this may mean
## Key considerations
## Questions for the congenital heart team
"""
    return ask_agent(
        system_prompt,
        f"Diagnosis: {diagnosis}\n\nEvidence:\n{evidence}\n\nQuestion:\n{question}",
    )


def exercise_agent(question, diagnosis, activity, risk, evidence):
    system_prompt = """
You are the Pediatric Cardiac Exercise & Rehabilitation Agent.

Focus on physical activity, sports, exercise tolerance and rehabilitation in CHD.
Never provide sports clearance or an individualized exercise prescription.
Highlight symptoms and the need for individualized cardiology assessment.

Return:
# Exercise & Rehabilitation Perspective
## Activity considerations
## Safety considerations
## Questions for cardiology / exercise testing
"""
    return ask_agent(
        system_prompt,
        (
            f"Diagnosis: {diagnosis}\nActivity: {activity}\nRisk: {risk}\n\n"
            f"Evidence:\n{evidence}\n\nQuestion:\n{question}"
        ),
    )


def nutrition_agent(question, diagnosis, evidence):
    system_prompt = """
You are the Pediatric CHD Nutrition & Growth Agent.

Focus on feeding, appetite, growth, weight and dietitian support.
Do not prescribe a diet, formula concentration, calorie target or treatment.

Return:
# Nutrition & Growth Perspective
## Growth / feeding considerations
## Information the care team may need
## Questions for cardiology / dietitian
"""
    return ask_agent(
        system_prompt,
        f"Diagnosis: {diagnosis}\n\nEvidence:\n{evidence}\n\nQuestion:\n{question}",
    )


def surgery_agent(question, diagnosis, evidence):
    system_prompt = """
You are the Congenital Cardiac Surgery Education Agent.

Explain surgical concepts and questions families can discuss with congenital cardiac
surgeons. Never determine whether surgery is required, choose an operation, or predict
an individual's outcome.

Return:
# Cardiac Surgery Perspective
## Surgical considerations
## Information the surgical team may need
## Questions for the surgeon
"""
    return ask_agent(
        system_prompt,
        f"Diagnosis: {diagnosis}\n\nEvidence:\n{evidence}\n\nQuestion:\n{question}",
    )


def qol_agent(question, diagnosis, evidence):
    system_prompt = """
You are the Pediatric CHD Quality-of-Life Agent.

Focus on school, daily functioning, fatigue, social participation, emotional well-being
and adjustment to CHD. Do not diagnose mental illness or provide psychotherapy.

Return:
# Quality-of-Life Perspective
## Daily life / school considerations
## Emotional and social considerations
## Questions for the care team
"""
    return ask_agent(
        system_prompt,
        f"Diagnosis: {diagnosis}\n\nEvidence:\n{evidence}\n\nQuestion:\n{question}",
    )


def caregiver_agent(question, diagnosis, evidence):
    system_prompt = """
You are the CHD Caregiver Support & Family Navigation Agent.

Focus on practical caregiver support, preparing for appointments or surgery,
communication with the care team, siblings, care coordination, social work,
psychology and child-life resources. Do not diagnose or treat mental illness.

Return:
# Caregiver & Family Navigation Perspective
## Practical support
## Care-team preparation
## Resources that may help
"""
    return ask_agent(
        system_prompt,
        f"Diagnosis: {diagnosis}\n\nEvidence:\n{evidence}\n\nQuestion:\n{question}",
    )


# ============================================================
# DYNAMIC MULTI-AGENT ROUTER — NO EXTRA LLM CALL
# ============================================================

AGENT_DISPLAY_NAMES = {
    "education": "CHD Education",
    "exercise": "Exercise & Cardiac Rehabilitation",
    "nutrition": "Nutrition & Growth",
    "surgery": "Cardiac Surgery",
    "qol": "Quality of Life",
    "caregiver": "Caregiver & Family Navigation",
}


def route_agents(context, question):
    """
    Dynamic router:
    - uses extracted topics
    - applies deterministic clinical/family enrichment
    - limits specialist calls to control cost/latency
    """
    topics = list(context.get("topics", []))
    text = question.lower()

    # Multi-domain examples
    if any(term in text for term in ["gets tired", "tires easily", "cannot keep up"]):
        if "exercise" not in topics:
            topics.append("exercise")

    if "surgery" in topics and any(term in text for term in [
        "scared", "worried", "overwhelmed", "anxious"
    ]):
        if "caregiver" not in topics:
            topics.append("caregiver")

    if "exercise" in topics and any(term in text for term in [
        "school", "friends", "feels different", "quality of life"
    ]):
        if "qol" not in topics:
            topics.append("qol")

    if not topics:
        topics = ["education"]

    topics = list(dict.fromkeys(topics))

    # Prefer specialized topics over generic education.
    if len(topics) > 1 and "education" in topics:
        topics.remove("education")

    return topics[:MAX_SPECIALIZED_AGENTS]


def run_specialized_agents(question, context, evidence, guideline_text, safety):
    diagnosis = context.get("diagnosis", "Unknown")
    activity = context.get("activity") or "General Activity"

    risk_map = {
        "EMERGENCY": "HIGH",
        "URGENT": "MODERATE",
        "ROUTINE": "LOW",
    }
    risk = risk_map.get(safety["level"], "LOW")

    active_topics = route_agents(context, question)

    combined_evidence = f"""
PUBMED MATERIAL:
{evidence}

CURATED GUIDELINE MATERIAL:
{guideline_text}
"""

    responses = {}

    for topic in active_topics:
        if topic == "exercise":
            responses[topic] = exercise_agent(
                question, diagnosis, activity, risk, combined_evidence
            )
        elif topic == "nutrition":
            responses[topic] = nutrition_agent(
                question, diagnosis, combined_evidence
            )
        elif topic == "surgery":
            responses[topic] = surgery_agent(
                question, diagnosis, combined_evidence
            )
        elif topic == "qol":
            responses[topic] = qol_agent(
                question, diagnosis, combined_evidence
            )
        elif topic == "caregiver":
            responses[topic] = caregiver_agent(
                question, diagnosis, combined_evidence
            )
        else:
            responses["education"] = education_agent(
                question, diagnosis, combined_evidence
            )

    return active_topics, responses


# ============================================================
# FINAL RESPONSE COMPOSER
# ============================================================

def synthesize_agent_responses(
    question,
    context,
    active_topics,
    agent_responses,
    missing_information,
    safety,
):
    specialist_text = "\n\n".join(
        f"===== {AGENT_DISPLAY_NAMES.get(topic, topic)} =====\n{response}"
        for topic, response in agent_responses.items()
    )

    system_prompt = """
You are the final response composer for a CHD Family Copilot.

Synthesize specialist-agent outputs into ONE concise family-facing response.
Do not repeat the same information from multiple agents.

Rules:
- Never invent patient facts.
- Never diagnose, prescribe, provide sports clearance or determine surgery.
- Put the most actionable next step first.
- Do not claim a guideline recommendation unless supplied guideline material supports it.
- If missing information exists, identify it clearly.
- Keep the default response concise enough for a chat interface.
- Use family-friendly language.

Return exactly:
# What to Do Next
# What This May Mean
# Key Considerations
# Information That Would Help the Care Team
# Questions to Ask
# Evidence Summary
"""

    user_prompt = f"""
QUESTION:
{question}

PATIENT CONTEXT:
{json.dumps(context, indent=2)}

ACTIVE SPECIALIST TOPICS:
{json.dumps(active_topics)}

SAFETY:
{json.dumps(safety, indent=2)}

MISSING INFORMATION:
{json.dumps(missing_information)}

SPECIALIST OUTPUTS:
{specialist_text}
"""

    return ask_agent(system_prompt, user_prompt)


# ============================================================
# PROVIDER MATCHING AGENT
# ============================================================

def load_provider_database(filename=PROVIDER_FILE):
    path = Path(filename)
    if not path.exists():
        return []

    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return []

    if isinstance(data, list):
        providers = data
    elif isinstance(data, dict):
        providers = data.get("providers", [])
    else:
        providers = []

    normalized = []

    for provider in providers:
        item = dict(provider)

        combined_text = " ".join([
            str(item.get("name", "")),
            str(item.get("hospital", "")),
            str(item.get("department", "")),
            str(item.get("specialty", "")),
            str(item.get("title", "")),
            str(item.get("titles", "")),
            str(item.get("expertise", "")),
            str(item.get("biography", "")),
            str(item.get("departments_text", "")),
            str(item.get("matching_text", "")),
            " ".join(item.get("roles", []))
            if isinstance(item.get("roles"), list)
            else str(item.get("roles", "")),
        ])

        item["searchable_text"] = combined_text.lower()
        normalized.append(item)

    return normalized


PROVIDER_DATABASE = load_provider_database()


TOPIC_PROVIDER_KEYWORDS = {
    "exercise": [
        "exercise", "rehabilitation", "cardiac rehabilitation",
        "exercise physiology", "sports", "fitness", "cardiopulmonary exercise"
    ],
    "nutrition": [
        "nutrition", "dietitian", "feeding", "growth", "gastroenterology"
    ],
    "surgery": [
        "cardiac surgery", "cardiothoracic surgery",
        "congenital cardiac surgery", "surgeon", "surgery"
    ],
    "qol": [
        "psychology", "behavioral health", "neurodevelopment",
        "social work", "quality of life", "mental health"
    ],
    "caregiver": [
        "social work", "psychology", "behavioral health", "child life",
        "family support", "care coordination", "nursing"
    ],
    "education": [
        "congenital cardiology", "cardiology", "pediatric cardiology"
    ],
}


def diagnosis_keywords(diagnosis):
    if diagnosis == "Unknown":
        return []
    return DIAGNOSIS_KEYWORDS.get(diagnosis, [diagnosis.lower()])


def recommend_providers(
    question,
    diagnosis,
    topics,
    hospital="Childrens National",
    top_n=3,
):
    if not PROVIDER_DATABASE:
        return []

    question_words = {
        word
        for word in re.findall(r"[a-zA-Z]{5,}", question.lower())
        if word not in {
            "about", "child", "daughter", "family", "should", "would",
            "could", "their", "there", "which", "please"
        }
    }

    condition_terms = diagnosis_keywords(diagnosis)
    matches = []

    for provider in PROVIDER_DATABASE:
        provider_hospital = str(provider.get("hospital", ""))

        if (
            hospital
            and provider_hospital
            and provider_hospital.lower() != hospital.lower()
        ):
            continue

        text = provider.get("searchable_text", "")
        department = str(provider.get("department", "")).lower()
        score = 0
        reasons = []

        for topic in topics:
            terms = TOPIC_PROVIDER_KEYWORDS.get(topic, [])
            hits = [term for term in terms if term in text]
            if hits:
                score += min(45, 15 + 8 * len(hits))
                reasons.append(
                    f"Public profile matches the {AGENT_DISPLAY_NAMES.get(topic, topic)} domain"
                )

            if topic == "surgery" and "surgery" in department:
                score += 30
                reasons.append("Cardiac/congenital surgery department match")

            if topic in {"exercise", "education"} and "cardiology" in department:
                score += 12

        diagnosis_hits = [term for term in condition_terms if term in text]
        if diagnosis_hits:
            score += min(35, 20 + 5 * len(diagnosis_hits))
            reasons.append(f"Public profile includes terms relevant to {diagnosis}")

        shared_words = [word for word in question_words if word in text]
        if shared_words:
            score += min(16, 4 * len(shared_words))
            reasons.append("Profile shares relevant terms with the family question")

        if provider.get("research_profile_url"):
            score += 3

        if score > 0:
            matches.append({
                "provider": provider,
                "score": score,
                "reasons": list(dict.fromkeys(reasons)),
            })

    matches.sort(
        key=lambda item: (item["score"], item["provider"].get("name", "")),
        reverse=True,
    )

    return matches[:top_n]


def provider_confidence(score):
    if score >= 80:
        return "High"
    if score >= 55:
        return "Moderate"
    return "Exploratory"


# ============================================================
# HALLUCINATION / EVIDENCE VERIFIER AGENT
# ============================================================

def should_run_verifier(verification_mode, safety, active_topics):
    if verification_mode == "always":
        return True
    if verification_mode == "off":
        return False

    # Smart mode: save cost on simple routine single-agent questions.
    return safety["level"] != "ROUTINE" or len(active_topics) > 1


def hallucination_verifier(answer, evidence, guideline_text):
    system_prompt = """
You are an evidence verification agent.

Compare the proposed family-facing answer ONLY against the supplied PubMed and
curated guideline material.

Return VALID JSON ONLY:
{
  "status": "PASS" or "REVIEW",
  "unsupported_claims": [],
  "citation_concerns": [],
  "overall_evidence_support": "HIGH" or "MODERATE" or "LOW"
}

Do not reveal chain-of-thought.
"""

    user_prompt = f"""
ANSWER:
{answer}

PUBMED MATERIAL:
{evidence}

CURATED GUIDELINE MATERIAL:
{guideline_text}
"""

    try:
        raw = ask_agent(system_prompt, user_prompt, temperature=0).strip()
        raw = re.sub(r"^```(?:json)?", "", raw)
        raw = re.sub(r"```$", "", raw)
        return json.loads(raw)
    except Exception:
        return {
            "status": "REVIEW",
            "unsupported_claims": [],
            "citation_concerns": ["Verifier output could not be parsed."],
            "overall_evidence_support": "LOW",
        }


# ============================================================
# AI GOVERNANCE AGENT
# ============================================================

def build_governance_data(
    safety,
    missing_information,
    verification,
    pubmed_count,
    guideline_count,
    active_topics,
):
    return {
        "safety_level": safety["level"],
        "human_review_recommended": (
            safety["human_review"] or verification.get("status") == "REVIEW"
        ),
        "missing_information": missing_information,
        "pubmed_records_retrieved": pubmed_count,
        "guidelines_retrieved": guideline_count,
        "verification_status": verification.get("status", "SKIPPED"),
        "evidence_support": verification.get("overall_evidence_support", "NOT ASSESSED"),
        "active_agents": [
            AGENT_DISPLAY_NAMES.get(topic, topic) for topic in active_topics
        ],
    }


# ============================================================
# CHIEF AGENT / ORCHESTRATOR
# ============================================================

def chief_agent(
    question,
    hospital="Childrens National",
    history=None,
    patient_context=None,
    return_details=False,
    verification_mode="smart",
):
    if not question or not question.strip():
        raise ValueError("Please enter a family question.")

    # ---------- Local conversational intents: zero LLM / zero PubMed ----------
    intent = detect_conversation_intent(question)

    if intent != "clinical":
        message = local_conversation_response(intent)

        result = {
            "kind": "conversation",
            "report": message,
            "patient_context": dict(patient_context or {}),
            "topics": [],
            "active_agents": [],
            "safety": {
                "level": "ROUTINE",
                "triggers": [],
                "human_review": False,
            },
            "missing_information": [],
            "providers": [],
            "evidence": "",
            "guidelines": "",
            "verification": {
                "status": "SKIPPED",
                "unsupported_claims": [],
                "citation_concerns": [],
                "overall_evidence_support": "NOT ASSESSED",
            },
            "governance": {
                "safety_level": "ROUTINE",
                "human_review_recommended": False,
                "missing_information": [],
                "pubmed_records_retrieved": 0,
                "guidelines_retrieved": 0,
                "verification_status": "SKIPPED",
                "evidence_support": "NOT ASSESSED",
                "active_agents": [],
            },
        }

        return result if return_details else message

    # ---------- Context / memory ----------
    extracted = extract_context(
        question=question,
        history=history,
        patient_context=patient_context,
    )

    updated_context = merge_patient_context(patient_context, extracted)

    # Update mutable Streamlit session dictionary in place.
    if isinstance(patient_context, dict):
        patient_context.clear()
        patient_context.update(updated_context)

    diagnosis = updated_context.get("diagnosis", "Unknown")

    # ---------- Safety ----------
    safety = safety_agent(question, updated_context)

    # ---------- Dynamic router ----------
    active_topics = route_agents(updated_context, question)
    updated_context["topics"] = active_topics

    # ---------- Missing information ----------
    missing_information = detect_missing_information(updated_context)

    # ---------- PubMed, with caching ----------
    all_articles = []

    for topic in active_topics:
        all_articles.extend(
            evidence_agent.search(diagnosis=diagnosis, topic=topic)
        )

    deduped = {}
    for article in all_articles:
        pmid = article.get("PMID") or str(id(article))
        deduped[pmid] = article

    all_articles = list(deduped.values())
    evidence = summarize_evidence(all_articles)

    # ---------- Curated guidelines ----------
    guidelines = retrieve_guidelines(diagnosis, active_topics)
    guideline_text = format_guidelines(guidelines)

    # ---------- Specialized multi-agent collaboration ----------
    active_topics, specialist_responses = run_specialized_agents(
        question=question,
        context=updated_context,
        evidence=evidence,
        guideline_text=guideline_text,
        safety=safety,
    )

    # ---------- One final synthesis ----------
    report = synthesize_agent_responses(
        question=question,
        context=updated_context,
        active_topics=active_topics,
        agent_responses=specialist_responses,
        missing_information=missing_information,
        safety=safety,
    )

    # ---------- Explainable provider matching ----------
    provider_matches = recommend_providers(
        question=question,
        diagnosis=diagnosis,
        topics=active_topics,
        hospital=hospital,
        top_n=3,
    )

    # ---------- Verification (smart to control cost) ----------
    if should_run_verifier(verification_mode, safety, active_topics):
        verification = hallucination_verifier(
            answer=report,
            evidence=evidence,
            guideline_text=guideline_text,
        )
    else:
        verification = {
            "status": "SKIPPED",
            "unsupported_claims": [],
            "citation_concerns": [],
            "overall_evidence_support": "NOT ASSESSED",
        }

    governance = build_governance_data(
        safety=safety,
        missing_information=missing_information,
        verification=verification,
        pubmed_count=len(all_articles),
        guideline_count=len(guidelines),
        active_topics=active_topics,
    )

    active_names = ", ".join(
        AGENT_DISPLAY_NAMES.get(topic, topic) for topic in active_topics
    )

    header = f"""
# CHD Family Copilot Assessment

**Diagnosis:** {diagnosis}

**Age:** {updated_context.get("age") if updated_context.get("age") is not None else "Not provided"}

**Active topic(s):** {", ".join(active_topics)}

**Activity:** {updated_context.get("activity") or "Not provided"}

**Safety:** {safety["level"]}

**Specialized agents:** {active_names}

**Hospital directory:** {hospital}
""".strip()

    final_report = f"""
{header}

---

{report}

---

# Important Safety Notice

This research prototype provides educational and care-navigation support only.
It does not diagnose, prescribe treatment, provide sports clearance, determine
whether surgery is needed, or replace the treating congenital heart team.

For severe symptoms, fainting, significant breathing difficulty, persistent
chest pain, blue coloration, unresponsiveness, or another medical emergency,
seek immediate medical care.
""".strip()

    result = {
        "kind": "clinical",
        "report": final_report,
        "patient_context": updated_context,
        "topics": active_topics,
        "active_agents": [
            AGENT_DISPLAY_NAMES.get(topic, topic) for topic in active_topics
        ],
        "safety": safety,
        "missing_information": missing_information,
        "providers": provider_matches,
        "evidence": evidence,
        "guidelines": guideline_text,
        "verification": verification,
        "governance": governance,
    }

    return result if return_details else final_report
