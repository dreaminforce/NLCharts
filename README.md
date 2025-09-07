# Natural Language Charts in Salesforce (Apex + LWC)

Turn plain-English questions into **safe SOQL datasets** and a **ready-to-share chart** without leaving Salesforce.


---

## Table of Contents

* [Overview](#overview)
* [Architecture](#architecture)
* [Components](#components)
* [How It Works (End-to-End Flow)](#how-it-works-end-to-end-flow)
* [Project Structure](#project-structure)
* [Setup](#setup)
* [Configuration](#configuration)
* [Usage](#usage)
* [Security & Governance](#security--governance)
* [Limits & Performance](#limits--performance)
* [Troubleshooting](#troubleshooting)
* [FAQ](#faq)
* [Roadmap / Ideas](#roadmap--ideas)
* [License](#license)

---

## Overview

This pattern lets users ask Salesforce questions in natural language (e.g., “Pipeline by stage this quarter”), then:

1. builds a **plan** (SOQL datasets + chart spec) via an LLM,
2. validates the plan (read-only, allowlist, FLS aware, row caps),
3. runs the SOQL, produces **CSVs**,
4. hands those CSVs to an Assistant with **Code Interpreter** to render a **chart.png**,
5. stores results in **Salesforce Files** and shows them in a **Lightning Web Component**.

The focus is **structure & behavior**, not bespoke charting logic.

---

## Architecture

**Inside Salesforce**

* **Apex (`NLChartController`)**

  * Plan (Chat Completions)
  * Validate (allowlist, `LIMIT`, FLS/User Mode)
  * Execute SOQL → CSV
  * Upload CSVs to Assistant
  * Create thread + run, poll status
  * Persist outputs to Files and return URLs
* **LWC (`nlChart`)**

  * Prompt input
  * Timeline of steps (Plan → Validate → SOQL → Upload → Assistant → Save)
  * CSV download links
  * Chart preview (`chart.png`)
* **Files (`ContentVersion`)**

  * Stores each dataset CSV and the generated chart

**Outside Salesforce**

* **Chat Completions** (returns strict JSON “plan”)
* **Assistants v2 + Code Interpreter** (reads CSVs, applies chart spec, writes `chart.png` and optional `summary.txt`)

---

## Components

### Apex: `NLChartController`

* `startRun(promptText)`
  Plans → validates → executes SOQL → uploads datasets → starts assistant run → saves CSVs → returns `jobId` and CSV file IDs.
* `pollRun(jobId)`
  Polls run status; when completed, downloads `chart.png`, saves to Files, returns chart download URL.
* Validation helpers:

  * **Strict main-object check** (first token after `FROM`)
  * **FLS enforcement** (`WITH USER_MODE` or `WITH SECURITY_ENFORCED`) injected **immediately after `FROM <Object>`**
  * Row caps (`LIMIT <= 2000`)
  * Optional PII token guard
* OpenAI helpers: file upload (multipart), thread/run create, list messages, file download.

### LWC: `nlChart`

* **HTML**: prompt box, run button/spinner, step timeline, CSV list, chart image.
* **JS**: orchestrates `startRun` → `pollRun`, updates step states and messages.
* **Meta**: exposed on App/Home/Record/Tab for easy internal testing.
* **CSS**: light—relies on SLDS.

---

## How It Works (End-to-End Flow)

1. **Prompt (LWC)**
   User types: “Pipeline by stage this quarter; bar chart; counts and sum of Amount.” LWC calls `startRun(promptText)`.

2. **Plan (Apex → Chat Completions)**
   Apex requests strict JSON:

   ```json
   {
     "datasets": [{"name":"...","purpose":"...","soql":"SELECT ... LIMIT 2000"}],
     "chart": {"title":"...","type":"bar|line|pie|combo","spec":{}, "notes":"..."}
   }
   ```

3. **Validate (Apex)**

   * Reject DML/tooling/sosl/unsafe tokens.
   * **Allowlist**: Account, Contact, Opportunity, Case.
   * **FLS/User Mode**: insert `WITH USER_MODE` (or `WITH SECURITY_ENFORCED`) **right after `FROM <Object>`**.
   * Require and cap `LIMIT`.

4. **Execute (Apex)**
   Run each SOQL (sharing/FLS honored) → flatten to CSV with stable headers.

5. **Upload & Run (Apex → Assistants)**
   Upload CSVs, create thread with `code_interpreter` attachments, start run.

6. **Persist (Apex)**
   Save CSVs to Files for transparency / audit.

7. **Poll & Collect (Apex + LWC)**
   LWC polls `pollRun(jobId)` until complete. Apex fetches first assistant-produced file (image), downloads `chart.png`, saves to Files, returns URL.

8. **Present (LWC)**
   Timeline ticks to **Done**, CSV links show up, chart renders inline.

---

## Project Structure

```
force-app/
  main/default/
    classes/
      NLChartController.cls
      NLChartController.cls-meta.xml
    lwc/
      nlChart/
        nlChart.html
        nlChart.js
        nlChart.css
        nlChart.js-meta.xml
```

---

## Setup

1. **Prereqs**

   * Salesforce org with API access
   * SLDS available (standard in Lightning runtime)
   * Remote Site Setting for `https://api.openai.com`
   * Assistant with **Code Interpreter** enabled (and note the `assistant_id`)

2. **Deploy**

   * Push the Apex class & LWC.
   * Expose the LWC via **Lightning App Builder**: add to an **App Page** or **Tab** for internal testing.

3. **Permissions**

   * Users need read access to the allowed objects and to Files they create.
   * The Apex class runs **with sharing**; FLS/User Mode is enforced at query time.

4. **OpenAI Access**

   * For development: constants in Apex are used (see **Configuration**).
   * For production: replace hardcoded key with **Named Credential** and a protected custom metadata reference.

---

## Configuration

| Constant                        | Purpose                          | Example                               |
| ------------------------------- | -------------------------------- | ------------------------------------- |
| `OPENAI_BASE`                   | API base                         | `https://api.openai.com`              |
| `OPENAI_MODEL_FOR_PLAN`         | Chat Completions planning model  | `gpt-4.1-mini`                        |
| `OPENAI_ASSISTANT_ID`           | Target Assistant ID (CI enabled) | `asst_xxx`                            |
| `ALLOWED_OBJECTS`               | SOQL main-object allowlist       | `account, contact, opportunity, case` |
| `MAX_LIMIT`                     | Row cap per query                | `2000`                                |
| `MAX_DATASETS`, `MAX_CSV_BYTES` | Run budget caps                  | `5`, `3000000`                        |

> **Production tip:** use **Named Credentials** for the API key; rotate keys regularly. In the dev branch we keep it constant for simplicity.

---

## Usage

1. Open the page containing **Natural Language Chart**.
2. Enter a prompt, e.g.:

   * “Opportunity counts by StageName this quarter; bar chart.”
   * “Cases by Priority this month; show counts and aging buckets; combo chart.”
3. Click **Run**. Watch the timeline as it progresses.
4. Download **CSVs** for each dataset as needed.
5. View **chart** inline (saved as Files → `chart.png`).

---

## Security & Governance

* **Row-level:** `with sharing` respects the caller’s sharing rules.
* **Field-level:** queries run with **User Mode / Security Enforced** by injecting `WITH USER_MODE` (or `WITH SECURITY_ENFORCED`) **immediately after `FROM <Object>`**.
* **Scope:** strict main-object allowlist; first token after `FROM` is matched (no substring bypass like `OpportunityHistory`).
* **Volume:** mandatory `LIMIT` per dataset and a global byte/dataset budget.
* **Data egress:** only CSVs produced by your queries are sent to the Assistant; generated images are stored back in Files.

---

## Limits & Performance

* Designed to be **governor-friendly** (read-only SOQL, clear callout phases).
* CSV headers are **stable** (sorted union of populated fields).
* Multipart upload uses **base64** in the file part (Apex-friendly and accepted by the API).
* Polling happens in the **LWC** (client-side), not in long-running Apex loops.

---

## Troubleshooting

**“No plan returned from model”**

* Ensure Chat Completions call **doesn’t** include the Assistants beta header.
* Log and inspect the raw body; confirm `choices[0].message.content` is present JSON.

**`unexpected token: 'count'` on aggregate queries**

* The FLS clause must be injected **right after `FROM <Object>`** (before `GROUP BY/ORDER BY/LIMIT`). Use `WITH USER_MODE` or `WITH SECURITY_ENFORCED`.

**Compile error: `Extra ';', at '_000_000'`**

* Apex doesn’t support `_` in numbers. Use `3000000`, not `3_000_000`.

**Multipart upload issues**

* Using base64 with `Content-Transfer-Encoding: base64` is expected in Apex. Verify boundary formatting and headers.

**Images not found in messages**

* When parsing thread messages, prefer **`role=assistant`** to avoid picking user-attached files.

**Nothing renders**

* Check Remote Site Settings for `api.openai.com`.
* Ensure the Assistant has **Code Interpreter** enabled and the run status reaches `completed`.

---

## FAQ

**Why not Reports/Dashboards?**
This is for **ad-hoc exploratory** visuals when users want fast iterations without setting up a report. It doesn’t replace curated dashboards.

**Which objects are allowed?**
By default: `Account`, `Contact`, `Opportunity`, `Case`. Extend cautiously by updating the allowlist.

**Can I use `WITH USER_MODE` instead of `WITH SECURITY_ENFORCED`?**
Yes—prefer it if supported in your org. It enforces CRUD/FLS comprehensively. The injector logic places it right after `FROM`.

**Does the Assistant return insights?**
The instruction also asks for `summary.txt` (3 bullets). You can extend the controller to store and display it.

**Can I upload large datasets?**
Budgets are enforced (`MAX_DATASETS`, `MAX_CSV_BYTES`). Tune with care; large CSVs inflate heap and callout time.

---

## Roadmap / Ideas

* Surface **`summary.txt`** (assistant insights) next to the chart.
* Add **run history** (custom object) for audit and reuse.
* Expand chart spec for dual-axis/stacked/grouped variants.
* Add **Named Credential** integration by default.
* Optional **PII allow-deny lists** per org policy.

---

## License

This project is provided as-is for internal enablement and experimentation. Review your organization’s security, compliance, and data handling standards before production use.
