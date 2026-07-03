# DG Bank — AI Banking Demo

A fictional banking web app that demonstrates **Trend Micro Vision One AI Application Security** (AI Guard + AI Scanner) and **Vision One Code Security** alongside **Amazon Bedrock** (Claude) in a realistic customer-facing scenario.

Built for Sales Engineers to deploy in their own AWS account and use during customer demos.

---

## Trend Micro product integrations

| Product | Capability showcased |
|---|---|
| **Vision One AI Application Security — AI Guard** | Real-time prompt and response scanning. Intercepts every message sent to the chatbot and blocks malicious prompts (prompt injection, jailbreak, PII exfil, etc.) before they reach the model. Toggle between Guard Off, Demo (local pattern matching), and Guard On (live Vision One API). |
| **Vision One AI Application Security — AI Scanner** | Automated red-team attack campaigns using TMAS `aiscan llm`. Generates attack prompts across configurable objectives (Sensitive Data Disclosure, System Prompt Leakage, Malicious Code Generation, Agent Tool Definition Leakage), streams results live via SSE, and exports a full report. |
| **Vision One Code Security** | Static analysis of the application source code during CI/CD. The GitHub Actions pipeline runs a TMAS artifact scan on every push, surfacing vulnerabilities before the container image reaches ECS. |

---

## What's in the demo

| Feature | Description |
|---|---|
| **C-3PO, The Assistant** | AI chatbot powered by Amazon Bedrock (Claude 3 Haiku) |
| **AI Guard** | Vision One prompt scanning — Demo, Guard On, or Guard Off modes |
| **Malicious Prompts** | Pre-built attack presets (prompt injection, jailbreak, social engineering, PII exfil) to trigger AI Guard |
| **AI Scanner** | Automated attack campaign powered by TMAS `aiscan llm` — streams live results via SSE, exports a full report |
| **Banking UI** | Realistic dashboard with account balance, transactions, cards, and quick actions |

---

## Deploy (fresh account)

### Prerequisites

- AWS CLI configured (`aws configure`)
- Docker installed and running
- An ACM wildcard certificate in your region (e.g. `*.hawkins.global`) — optional, for HTTPS

### One-command deploy

```bash
./deploy-ecs.sh --github-org <your-github-username>
```

With HTTPS:

```bash
./deploy-ecs.sh \
  --github-org <your-github-username> \
  --certificate-arn arn:aws:acm:<region>:<account>:certificate/<id>
```

The script will:
1. Create the ECR repository
2. Build and push the Docker image (`linux/amd64`)
3. Deploy the CloudFormation stack (VPC, ECS on EC2, ALB, IAM, OIDC)
4. Wait for the service to be healthy
5. Print the app URL, DNS target, and GitHub Actions role ARN

### After deploy

The script prints two things to finish setup:

**1. DNS** — add a CNAME at your DNS provider:
```
bank.hawkins.global  →  <ALB DNS name printed by script>
```

**2. GitHub Actions secret** — go to your repo → Settings → Secrets and variables → Actions:
```
AWS_ROLE_ARN = <role ARN printed by script>
```

After that, every push to `main` automatically builds and deploys to ECS.

### Re-deploy / update

```bash
./deploy-ecs.sh --github-org <your-github-username> --skip-oidc [--certificate-arn <arn>]
```

Use `--skip-oidc` on re-runs to avoid conflicts with the existing GitHub OIDC provider.

### Script options

| Option | Default | Description |
|---|---|---|
| `--github-org` | *(required)* | Your GitHub username or org |
| `--github-repo` | `ai-banking-app` | Repository name |
| `--region` | `ap-southeast-1` | AWS region |
| `--instance-type` | `t3.small` | EC2 instance type |
| `--bedrock-region` | `ap-southeast-1` | Bedrock API region |
| `--bedrock-model` | `anthropic.claude-3-haiku-20240307-v1:0` | Bedrock model ID |
| `--certificate-arn` | *(empty)* | ACM cert ARN for HTTPS |
| `--skip-oidc` | *(off)* | Skip OIDC provider creation |
| `--stack-name` | `dgbank-ai-app-demo-ecs` | CloudFormation stack name |

---

## Using the app

### Banking Queries tab

The default tab. Type any banking question or use the preset chips:

- **Account balance** — ask C-3PO for your balance
- **Recent transactions** — get a transaction summary
- **Transfer money** — initiate a transfer
- **Interest rates**, **Investment options**, **Replace card**, **Credit status**, **Auto bill pay**

C-3PO responds using Amazon Bedrock (Claude). Responses are scoped to banking — it will not answer off-topic questions.

### AI Guard

The **Guard** pill in the chat header controls scanning mode:

| State | Behaviour |
|---|---|
| **Guard Off** | Messages go straight to Bedrock, no scanning |
| **Demo** | Pattern-matching locally — no API call needed, great for offline demos |
| **Guard On** | Live Vision One API scanning on every message |

Click the pill to cycle between states. Configure Vision One credentials in **Settings** (gear icon).

**Setup for live mode:**
1. Click the gear icon → AI Guard Configuration
2. Enter your Vision One API key and select your region
3. Optionally enter a Guard ID / App Name (shown in Vision One dashboard)
4. Click **Save & Enable**
5. Click the Guard pill to switch to **Guard On**

### Malicious Prompts tab

Pre-built attack prompts to demonstrate AI Guard blocking:

| Preset | Attack type |
|---|---|
| Prompt Injection | Override system instructions |
| Jailbreak / DAN | Bypass AI safety guidelines |
| Social Engineering | Impersonate bank IT to extract data |
| Financial Fraud | Request money laundering assistance |
| PII Exfiltration | Extract customer personal data |
| Competitor Intel | Extract internal business data |

With **Guard On** or **Demo** mode active, these will be blocked before reaching Bedrock. With **Guard Off**, they reach the model (which may still refuse, but no Vision One event is generated).

### AI Scanner

Click the **AI Scanner** button (top navigation) to run an automated attack campaign powered by **TMAS `aiscan llm`**:

**Demo mode** — runs a built-in set of attack prompts directly against any endpoint using the `/api/scanner/run` endpoint. No additional credentials needed.

**Live mode** — uses TMAS to generate and evaluate attack prompts professionally, streaming real-time progress via Server-Sent Events (SSE). Requires `TMAS_API_KEY` to be set on the server (see GitHub Actions secrets below).

Workflow:
1. **Step 1 — Target** — enter the chat endpoint URL (defaults to the local chatbot at `/api/chat`). Optionally provide an API key and model name.
2. **Step 2 — Attack Objectives** — choose which attack categories to test (Sensitive Data Disclosure, System Prompt Leakage, etc.) and the techniques/modifiers to apply.
3. **Step 3 — Run** — click **Launch Scan**. In Live mode, a terminal streams TMAS output in real time. When complete, a per-objective summary shows how many techniques were blocked vs. passed.
4. **Export** — download a full text report including the scan log.

> **Live mode note:** objectives `Model Discovery` and `Hallucination` are not supported by TMAS `aiscan llm` and fall back to the built-in prompt runner.

---

## Architecture

```
Browser
  └── ALB (HTTPS port 443, HTTP → HTTPS redirect)
        └── ECS Service (EC2, t3.small)
              └── Node.js container (port 3000)
                    ├── /api/chat                        → Amazon Bedrock (Claude)
                    ├── /api/aiguard/scan                → Vision One AI Application Security
                    ├── /api/scanner/run                 → built-in attack runner (demo mode)
                    ├── POST /api/scanner/tmas           → starts TMAS aiscan llm job (returns jobId)
                    └── GET  /api/scanner/tmas/events/:jobId  → SSE stream of scan progress/results
```

**AWS resources created by `deploy-ecs.sh`:**

- VPC with 2 public subnets across AZs
- Internet Gateway + route tables
- Application Load Balancer (HTTP + HTTPS)
- ECS Cluster on EC2 with Auto Scaling Group
- ECS Task Role with Bedrock invoke permissions
- GitHub Actions IAM Role (OIDC) for CI/CD
- CloudWatch Log Group (`/ecs/dgbank-ai-app-demo`)

---

## GitHub Actions secrets

| Secret | Required | Description |
|---|---|---|
| `AWS_ROLE_ARN` | Yes | IAM role ARN printed by `deploy-ecs.sh` |
| `TMAS_API_KEY` | No | Vision One API key with **AI Application Security** scope — used in two ways: (1) enables the `tmas artifact scan` step in CI, and (2) stored in AWS SSM (`/dgbank/tmas-api-key`) and injected into ECS to power AI Scanner Live mode |

> **Getting the Vision One API key:** in the Vision One console go to **Administration → API Keys** and create a key with the *AI Application Security* permission. This is a different key from standard Bedrock/AWS credentials. Set it as the `TMAS_API_KEY` GitHub Actions secret and the CI pipeline will push it to SSM automatically on the next run.

---

## Local development

```bash
npm install
npm start
# → http://localhost:3000
```

Bedrock calls will fail locally unless you have AWS credentials configured with Bedrock access. The app falls back gracefully — the UI still loads and AI Guard demo mode works without any AWS credentials.
